/**
 * dsh-widget-bridge — a local-only bridge between a macOS desktop widget and
 * DeepSeek Harness sessions.
 *
 * Design constraints:
 * - Listen on 127.0.0.1 only, on an OS-assigned port.
 * - Require a random per-process bearer token; never expose DSH cookies or
 *   credentials. The widget reads the token from a 0600 discovery file.
 * - Use the Host's sessionController directly; do not read DSH credential
 *   files, process memory, or the launch URL token.
 */
import { createServer } from "node:http";
import { randomBytes, randomUUID } from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, sep } from "node:path";

const DEFAULT_DISCOVERY = join(homedir(), ".dsh", "widget-bridge.json");
const DEFAULT_LIMIT = 500;
const MAX_BODY_BYTES = 1024 * 1024;
// A pasted screenshot is base64 inside the prompt body, so this route needs a
// much larger ceiling than the control-plane routes.
const MAX_PROMPT_BODY_BYTES = 32 * 1024 * 1024;
const MAX_PROMPT_IMAGES = 8;
const HEARTBEAT_MS = 15000;
// maxMessages counts event records, not chat messages. Ask DSH for both a
// bounded event window and a minimum conversation window so opening a long
// session still shows a few rounds instead of only the latest tool events.
const TURN_WINDOW = Object.freeze({ minMessages: 20, minTurns: 2 });
const HISTORY_MIN_MESSAGES = 20;
const HISTORY_PAGE_GUARD = 8;
const HISTORY_ALL_PAGE_GUARD = 200;
const HISTORY_AFTER_PAGE_GUARD = 200;

function json(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

function errorBody(error) {
  const code = typeof error?.code === "string" ? error.code : "gateway/internal";
  const message = error instanceof Error ? error.message : String(error);
  return { error: { code, message } };
}

function statusFor(error) {
  const code = typeof error?.code === "string" ? error.code : "";
  if (code === "gateway/bad-request" || code.endsWith("-invalid")) return 400;
  if (code === "session/not-found" || code === "subagent/not-found" || code === "workspace/not-found") return 404;
  if (code === "session/agent-busy" || code === "session/writer-held") return 409;
  return 500;
}

// Attachment ids are content-addressed; remember the media type reported with
// each image block so /v1/attachments can answer with the right content type.
const attachmentTypes = new Map();

function partsOfContent(content) {
  const result = { text: "", reasoning: "", attachments: [] };
  if (typeof content === "string") {
    result.text = content;
    return result;
  }
  if (!Array.isArray(content)) return result;
  for (const block of content) {
    if (!block || typeof block !== "object") continue;
    if (block.type === "text" && typeof block.text === "string") {
      result.text += block.text;
      continue;
    }
    if (block.type === "reasoning" && typeof block.text === "string") {
      result.reasoning += block.text;
      continue;
    }
    if (block.type === "image" && block.attachment) {
      const a = block.attachment;
      if (typeof a.attachmentId !== "string") continue;
      if (typeof a.mediaType === "string") attachmentTypes.set(a.attachmentId, a.mediaType);
      result.attachments.push({
        attachmentId: a.attachmentId,
        mediaType: typeof a.mediaType === "string" ? a.mediaType : null,
        bytes: Number.isSafeInteger(a.bytes) ? a.bytes : null,
        width: Number.isSafeInteger(a.width) ? a.width : null,
        height: Number.isSafeInteger(a.height) ? a.height : null,
        name: typeof a.name === "string" ? a.name : null,
      });
    }
  }
  return result;
}

function textOfContent(content) {
  return partsOfContent(content).text;
}

/// One readable line for the status row: what this tool call is actually doing.
/// run_code carries a human description, the others carry their main argument.
function summarizeToolArguments(name, raw) {
  let args = raw;
  if (typeof raw === "string") {
    try { args = JSON.parse(raw); } catch { args = null; }
  }
  const pick = (value) => (typeof value === "string" && value.trim() ? value : null);
  let text = null;
  if (args && typeof args === "object") {
    const description = pick(args.description);
    if (name === "run_code") {
      text = description ?? pick(args.code);
    } else if (name === "bash" || name === "shell") {
      text = pick(args.command) ?? description;
    } else if (name === "grep" || name === "rg") {
      text = pick(args.pattern) ?? description;
    } else if (name === "read" || name === "write" || name === "edit") {
      text = pick(args.file_path) ?? pick(args.path) ?? description;
    } else {
      text = description
        ?? pick(args.command)
        ?? pick(args.pattern)
        ?? pick(args.query)
        ?? pick(args.file_path)
        ?? pick(args.url);
    }
  }
  if (!text && typeof raw === "string") text = raw;
  if (!text) return "";
  const flat = String(text).replace(/\s+/g, " ").trim();
  // The App wraps the summary over as many lines as it needs, so keep more of
  // the command here; only a whole file of code gets cut.
  return flat.length > 300 ? flat.slice(0, 299) + "…" : flat;
}

function eventToMessage(event) {
  if (!event || typeof event !== "object") return null;
  if (event.type === "user/message") {
    if (event.data?.source?.kind !== "user") return null;
    const parts = partsOfContent(event.data.content);
    if (!parts.text.trim() && parts.attachments.length === 0) return null;
    return {
      id: event.data.id ?? null,
      role: "user",
      text: parts.text,
      attachments: parts.attachments,
      seq: event.seq,
      time: event.time,
    };
  }
  if (event.type === "assistant/message") {
    const parts = partsOfContent(event.data?.message?.content);
    if (!parts.text.trim() && parts.attachments.length === 0) return null;
    return {
      id: event.data.message?.id ?? null,
      role: "assistant",
      text: parts.text,
      attachments: parts.attachments,
      seq: event.seq,
      time: event.time,
      turn: event.data.turn,
      step: event.data.step,
    };
  }
  return null;
}

function messagesFromSnapshot(snapshot) {
  const records = Array.isArray(snapshot?.records) ? snapshot.records : [];
  const messages = [];
  for (const record of records) {
    if (record?.type !== "event") continue;
    const message = eventToMessage(record.event);
    if (message) messages.push(message);
  }
  return messages;
}

function shortId(id) {
  return typeof id === "string" ? id.slice(0, 8) : "未命名";
}

function listTitle(row) {
  const values = row?.projections?.values;
  const candidates = [
    row?.title,
    values?.sessionTitle,
    values?.title,
    values?.sessionListMetadata?.title,
  ];
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim()) return candidate.trim();
  }
  const cwd = typeof row?.cwd === "string" ? row.cwd : "";
  return cwd ? basename(cwd) : shortId(row?.sessionId);
}

function normalizeSession(row) {
  return {
    id: row.sessionId,
    title: listTitle(row),
    cwd: typeof row.cwd === "string" ? row.cwd : null,
    updatedAt: Number(row.updatedAt) || 0,
    running: row.running === true,
    blank: row.blank === true,
    agentAvailable: row.agentAvailable === true,
    formatStatus: row.formatStatus ?? null,
  };
}

function readBody(req, limit = MAX_BODY_BYTES) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(Object.assign(new Error("request body too large"), { code: "gateway/bad-request" }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        const text = Buffer.concat(chunks).toString("utf8").trim();
        resolve(text ? JSON.parse(text) : {});
      } catch (error) {
        reject(Object.assign(new Error("invalid JSON body"), { code: "gateway/bad-request", cause: error }));
      }
    });
    req.on("error", reject);
  });
}

function clampLimit(value) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return DEFAULT_LIMIT;
  return Math.min(parsed, 500);
}

function parseAfterSeq(value) {
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    const error = new Error("after must be a non-negative integer sequence number");
    error.code = "gateway/bad-request";
    throw error;
  }
  return parsed;
}

export class WidgetBridge {
  constructor(options = {}) {
    this.host = options.host ?? "127.0.0.1";
    this.port = Number.isInteger(options.port) ? options.port : 0;
    this.token = options.token ?? randomBytes(32).toString("hex");
    this.discoveryPath = options.discoveryPath ?? DEFAULT_DISCOVERY;
    this.logger = options.logger ?? console;
    this.controller = options.controller ?? null;
    this.registry = options.registry ?? null;
    // Resolved lazily: the attachment service may register after the bridge
    // starts, and the widget only needs it for image prompts.
    this.resolveAttachments = options.resolveAttachments ?? null;
    this.server = null;
    this.started = false;
    this.stopping = false;
    this.activeStreams = new Set();
    this.server = createServer((req, res) => {
      void this.handle(req, res).catch((error) => {
        try {
          json(res, statusFor(error), errorBody(error));
        } catch {}
      });
    });
  }

  attach(controller, registry = null) {
    this.controller = controller;
    this.registry = registry;
  }

  attachRegistry(registry) {
    if (registry) this.registry = registry;
  }

  requireController() {
    if (!this.controller) {
      const error = new Error("session controller is not ready");
      error.code = "gateway/internal";
      throw error;
    }
    return this.controller;
  }

  requireRegistry() {
    if (!this.registry) {
      const error = new Error("workspace registry is not ready");
      error.code = "gateway/internal";
      throw error;
    }
    return this.registry;
  }

  /**
   * DSH groups sessions by Workspace membership, not by cwd: a session created
   * with only `{cwd}` belongs to no Workspace and lands in "未分组". Resolve a
   * cwd to its registered Workspace so creation goes through `{workspaceId}`,
   * which attaches the new session on the Host side.
   */
  workspaceForCwd(cwd) {
    if (!cwd || !this.registry || typeof this.registry.list !== "function") return null;
    try {
      return this.registry.list().find((workspace) => workspace.path === cwd) ?? null;
    } catch {
      return null;
    }
  }

  /**
   * Attach pre-existing sessions whose cwd matches a registered Workspace but
   * which are not members of it yet (created before cwd resolution existed).
   * Runs once per Host start; archived sessions are never attached.
   */
  async attachOrphanSessions() {
    const registry = this.registry;
    if (!registry || typeof registry.list !== "function") return { attached: [] };
    const rows = await this.requireController().list({}, undefined);
    const sessions = (rows?.items ?? []).map(normalizeSession);
    const archived = new Set((registry.archivedSessionIds ?? []).map(String));
    const attached = [];
    for (const workspace of registry.list()) {
      const owned = new Set((workspace.sessionIds ?? []).map(String));
      for (const session of sessions) {
        if (!session.cwd || session.cwd !== workspace.path) continue;
        if (owned.has(session.id) || archived.has(session.id)) continue;
        try {
          await workspace.attachSession(session.id);
          owned.add(session.id);
          attached.push({ sessionId: session.id, workspaceId: workspace.id });
        } catch (error) {
          this.logger.error(
            "[dsh-widget-bridge] attach " + session.id + " -> " + workspace.id + " failed: " + String(error?.message ?? error),
          );
        }
      }
    }
    if (attached.length > 0) {
      this.logger.log("[dsh-widget-bridge] attached " + String(attached.length) + " orphan session(s) to their Workspace");
    }
    return { attached };
  }

  writeDiscovery() {
    mkdirSync(dirname(this.discoveryPath), { recursive: true });
    const payload = {
      version: 1,
      pid: process.pid,
      host: this.host,
      port: this.port,
      token: this.token,
      startedAt: new Date().toISOString(),
    };
    const temporary = this.discoveryPath + "." + String(process.pid) + ".tmp";
    writeFileSync(temporary, JSON.stringify(payload), { mode: 0o600 });
    chmodSync(temporary, 0o600);
    renameSync(temporary, this.discoveryPath);
    chmodSync(this.discoveryPath, 0o600);
  }

  removeDiscovery() {
    try {
      const current = JSON.parse(readFileSync(this.discoveryPath, "utf8"));
      if (current?.pid === process.pid) unlinkSync(this.discoveryPath);
    } catch {}
  }

  async start() {
    if (this.started) return this;
    if (this.stopping) throw new Error("bridge is stopping");
    await new Promise((resolve, reject) => {
      const onError = (error) => {
        this.server.off("listening", onListening);
        reject(error);
      };
      const onListening = () => {
        this.server.off("error", onError);
        resolve();
      };
      this.server.once("error", onError);
      this.server.once("listening", onListening);
      this.server.listen(this.port, this.host);
    });
    const address = this.server.address();
    if (!address || typeof address === "string") throw new Error("bridge did not bind a TCP port");
    this.port = address.port;
    this.started = true;
    this.writeDiscovery();
    this.logger.log("[dsh-widget-bridge] listening on " + this.host + ":" + String(this.port));
    return this;
  }

  async stop() {
    this.stopping = true;
    for (const controller of this.activeStreams) {
      try { controller.abort(); } catch {}
    }
    this.activeStreams.clear();
    if (this.server) {
      await new Promise((resolve) => {
        this.server.close(() => resolve());
        setTimeout(resolve, 500).unref?.();
      });
      this.server = null;
    }
    this.removeDiscovery();
    this.started = false;
  }

  authorized(req) {
    if (req.headers.origin) return false;
    const header = req.headers.authorization;
    if (typeof header !== "string" || !header.startsWith("Bearer ")) return false;
    const provided = header.slice("Bearer ".length).trim();
    if (provided.length !== this.token.length) return false;
    let mismatch = 0;
    for (let index = 0; index < provided.length; index += 1) {
      mismatch |= provided.charCodeAt(index) ^ this.token.charCodeAt(index);
    }
    return mismatch === 0;
  }

  /// Serve one content-addressed attachment from the DSH attachment store.
  /// The id must be a literal sha256 reference; the resolved path is checked to
  /// stay inside the store so it cannot be used to read arbitrary files.
  async serveAttachment(res, rawId) {
    let id = rawId;
    try {
      id = decodeURIComponent(rawId);
    } catch {
      // keep the raw value; validation below rejects it
    }
    const match = /^sha256:([0-9a-f]{64})$/u.exec(id);
    if (!match) {
      json(res, 400, { error: { code: "attachment/invalid", message: "bad attachment id" } });
      return;
    }
    const hex = match[1];
    const root = join(homedir(), ".dsh", "attachments", "v1", "objects");
    const file = join(root, hex.slice(0, 2), hex);
    if (!file.startsWith(root + sep)) {
      json(res, 400, { error: { code: "attachment/invalid", message: "bad attachment path" } });
      return;
    }
    try {
      const data = await readFile(file);
      res.writeHead(200, {
        "content-type": attachmentTypes.get(id) ?? "application/octet-stream",
        "content-length": data.length,
        "cache-control": "private, max-age=86400",
      });
      res.end(data);
    } catch {
      json(res, 404, { error: { code: "attachment/not-found", message: "attachment missing" } });
    }
  }

  async handle(req, res) {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    const pathname = url.pathname;

    if (pathname === "/v1/health" && req.method === "GET") {
      json(res, 200, { ok: true, pid: process.pid, version: 1 });
      return;
    }
    if (!pathname.startsWith("/v1/")) {
      json(res, 404, { error: { code: "gateway/not-found", message: "not found" } });
      return;
    }
    if (!this.authorized(req)) {
      json(res, 401, { error: { code: "gateway/unauthorized", message: "widget token required" } });
      return;
    }

    if (pathname.startsWith("/v1/attachments/") && req.method === "GET") {
      await this.serveAttachment(res, pathname.slice("/v1/attachments/".length));
      return;
    }

    if (pathname === "/v1/sessions" && req.method === "GET") {
      const rows = await this.requireController().list({}, undefined);
      json(res, 200, { sessions: (rows?.items ?? []).map(normalizeSession) });
      return;
    }

    if (pathname === "/v1/sessions" && req.method === "POST") {
      const body = await readBody(req);
      const cwd = typeof body.cwd === "string" && body.cwd.trim() ? body.cwd : undefined;
      const requestedWorkspaceId =
        typeof body.workspaceId === "string" && body.workspaceId.trim() ? body.workspaceId : null;
      let workspace = null;
      if (requestedWorkspaceId !== null) {
        workspace = this.requireRegistry().get(requestedWorkspaceId) ?? null;
        if (!workspace) {
          const error = new Error('workspace "' + requestedWorkspaceId + '" not found');
          error.code = "workspace/not-found";
          throw error;
        }
      } else if (cwd) {
        // Prefer a registered Workspace over a bare cwd: the Host only attaches
        // the new session when it is created through `workspaceId`.
        workspace = this.workspaceForCwd(cwd);
      }
      const request = workspace ? { workspaceId: workspace.id } : cwd ? { cwd } : {};
      const created = await this.requireController().create(request);
      json(res, 200, {
        sessionId: created.sessionId,
        agentPreset: created.agentPreset ?? null,
        workspaceId: workspace?.id ?? null,
      });
      return;
    }

    // Repair/undo workspace membership of an existing session.
    const workspaceMatch = /^\/v1\/sessions\/([^/]+)\/workspace$/u.exec(pathname);
    if (workspaceMatch) {
      const sessionId = decodeURIComponent(workspaceMatch[1]);
      const registry = this.requireRegistry();
      if (req.method === "POST") {
        const body = await readBody(req);
        const workspace = registry.get(String(body.workspaceId ?? "")) ?? null;
        if (!workspace) {
          const error = new Error('workspace "' + String(body.workspaceId ?? "") + '" not found');
          error.code = "workspace/not-found";
          throw error;
        }
        await workspace.attachSession(sessionId);
        json(res, 200, { sessionId, workspaceId: workspace.id, attached: true });
        return;
      }
      if (req.method === "DELETE") {
        const owner = registry
          .list()
          .find((workspace) => (workspace.sessionIds ?? []).map(String).includes(sessionId)) ?? null;
        if (!owner) {
          const error = new Error("session " + sessionId + " is not attached to any workspace");
          error.code = "workspace/not-found";
          throw error;
        }
        await owner.detachSession(sessionId);
        json(res, 200, { sessionId, workspaceId: owner.id, attached: false });
        return;
      }
    }

    const match = /^\/v1\/sessions\/([^/]+)\/(history|events|prompt|cancel)$/u.exec(pathname);
    if (match) {
      const sessionId = decodeURIComponent(match[1]);
      const action = match[2];
      if (action === "history" && req.method === "GET") {
        const limit = clampLimit(url.searchParams.get("limit"));
        const allValue = url.searchParams.get("all");
        const all = allValue === "1" || allValue === "true";
        const afterValue = url.searchParams.get("after");
        const afterSeq = afterValue === null ? null : parseAfterSeq(afterValue);
        if (all || afterSeq !== null) {
          const page = await this.readHistory(sessionId, limit, {
            all: all && afterSeq === null,
            afterSeq,
          });
          const seqs = page.messages.map((message) => message.seq).filter(Number.isSafeInteger);
          json(res, 200, {
            sessionId,
            messages: page.messages,
            hasMore: page.hasMore,
            oldestSeq: seqs.length ? Math.min(...seqs) : null,
            newestSeq: seqs.length ? Math.max(...seqs) : null,
          });
          return;
        }
        const snapshot = await this.readSnapshot(sessionId, limit);
        json(res, 200, {
          sessionId,
          messages: messagesFromSnapshot(snapshot),
          hasMore: snapshot?.hasMore === true,
        });
        return;
      }
      if (action === "events" && req.method === "GET") {
        await this.streamEvents(req, res, sessionId, clampLimit(url.searchParams.get("limit")));
        return;
      }
      if (action === "prompt" && req.method === "POST") {
        const body = await readBody(req, MAX_PROMPT_BODY_BYTES);
        const text = typeof body.text === "string" ? body.text : "";
        const images = Array.isArray(body.images) ? body.images : [];
        if (images.length > MAX_PROMPT_IMAGES) {
          const error = new Error(`at most ${MAX_PROMPT_IMAGES} images per message`);
          error.code = "gateway/bad-request";
          throw error;
        }
        if (!text.trim() && images.length === 0) {
          const error = new Error("text or images are required");
          error.code = "gateway/bad-request";
          throw error;
        }
        // DSH's own prompt admission normalizes encoded image parts, stores the
        // bytes durably, and records the sha256 reference in the session log.
        // Pre-admitting here would hand DSH already-resolved blocks, which its
        // admission rejects (surfaced as session/agent-busy).
        const content = [];
        if (text.trim()) content.push({ type: "text", text });
        for (const image of images) {
          const data = typeof image?.data === "string" ? image.data : "";
          const mediaType = typeof image?.mediaType === "string" ? image.mediaType : "";
          if (!data || !/^image\/(png|jpeg|webp|gif)$/u.test(mediaType)) {
            const error = new Error("each image needs base64 data and an image mediaType");
            error.code = "gateway/bad-request";
            throw error;
          }
          const part = { type: "image", data, mediaType };
          if (typeof image.name === "string" && image.name.trim()) part.name = image.name.trim();
          content.push(part);
        }
        // DSH's session controller requires a cancellation signal for prompt
        // admission and calls signal.throwIfAborted() before doing any work.
        // The bridge is not a streaming caller here, so a private signal that
        // is never aborted is enough; omitting it makes prompt() throw 500.
        const admission = new AbortController();
        const result = await this.requireController().prompt({
          sessionId,
          mode: "queue",
          content,
          requestId: randomUUID(),
        }, admission.signal).catch((error) => {
          // DSH masks admission failures as session/agent-busy; keep the
          // underlying reason in the bridge log for diagnosis.
          this.logger.error(
            "[dsh-widget-bridge] prompt rejected: " + String(error?.code ?? "") + " " +
              String(error?.message ?? error) + " " +
              JSON.stringify(error?.details ?? error?.data ?? null),
          );
          throw error;
        });
        json(res, 200, { accepted: result?.accepted === true });
        return;
      }
      if (action === "cancel" && req.method === "POST") {
        const result = await this.requireController().cancel({ sessionId });
        json(res, 200, { cancelled: result?.cancelled !== false });
        return;
      }
    }

    json(res, 404, { error: { code: "gateway/not-found", message: "not found" } });
  }

  /**
   * The follow snapshot is message-aligned but only covers the tail it can
   * reach in one paginate() pass. Backfill older message pages until the
   * widget has enough displayable history, not just raw event records.
   */
  async expandSnapshot(sessionId, snapshot, limit, signal) {
    const controller = this.requireController();
    // DSH calls signal.throwIfAborted() on every page() admission; a missing
    // signal turns a plain history read into a 500.
    const pageSignal = signal ?? new AbortController().signal;
    let records = Array.isArray(snapshot?.records) ? snapshot.records.slice() : [];
    let messages = messagesFromSnapshot({ records });
    let hasMore = snapshot?.hasMore === true;
    const seen = new Set(records.map((record) => record?.event?.seq).filter(Number.isSafeInteger));
    for (let page = 0; page < HISTORY_PAGE_GUARD && messages.length < HISTORY_MIN_MESSAGES && hasMore; page += 1) {
      const seqs = records.map((record) => record?.event?.seq).filter(Number.isSafeInteger);
      if (seqs.length === 0) break;
      const beforeSeq = Math.min(...seqs);
      if (beforeSeq <= 0) break;
      const older = await controller.page({
        address: { kind: "session", sessionId },
        throughSeq: snapshot.cursor,
        beforeSeq,
        maxMessages: limit,
        turnWindow: TURN_WINDOW,
      }, pageSignal);
      const pageRecordsValue = Array.isArray(older?.records) ? older.records : [];
      const fresh = pageRecordsValue.filter((record) => {
        const seq = record?.event?.seq;
        return Number.isSafeInteger(seq) && !seen.has(seq);
      });
      if (fresh.length === 0) break;
      for (const record of fresh) seen.add(record?.event?.seq);
      records = [...fresh, ...records];
      messages = messagesFromSnapshot({ records });
      hasMore = older?.hasMore === true;
    }
    return { ...snapshot, records, messages, hasMore };
  }

  async readTailSnapshot(sessionId, limit) {
    const controller = this.requireController();
    const abort = new AbortController();
    const iterator = controller.follow({
      address: { kind: "session", sessionId },
      maxMessages: limit,
      turnWindow: TURN_WINDOW,
      assistantStream: false,
    }, abort.signal)[Symbol.asyncIterator]();
    try {
      const first = await iterator.next();
      if (first.done) {
        // A brand-new session legitimately has no events yet. Return an empty
        // snapshot instead of turning "no history" into a 500.
        return { type: "snapshot", records: [], hasMore: false, cursor: 0 };
      }
      return first.value;
    } finally {
      abort.abort();
      try { await iterator.return?.(); } catch {}
    }
  }

  async readSnapshot(sessionId, limit) {
    const snapshot = await this.readTailSnapshot(sessionId, limit);
    return this.expandSnapshot(sessionId, snapshot, limit, undefined);
  }

  /**
   * Full import or incremental catch-up. DSH only pages backwards, so start
   * from the tail and walk back until the requested boundary (afterSeq) is
   * covered, or until the caller asked for everything. The page guard keeps a
   * corrupt/looping Host from turning this into an unbounded request.
   */
  async readHistory(sessionId, limit, { all = false, afterSeq = null } = {}) {
    const controller = this.requireController();
    const pageSignal = new AbortController().signal;
    const snapshot = await this.readTailSnapshot(sessionId, limit);
    let records = Array.isArray(snapshot?.records) ? snapshot.records.slice() : [];
    let messages = messagesFromSnapshot({ records });
    let hasMore = snapshot?.hasMore === true;
    const seen = new Set(records.map((record) => record?.event?.seq).filter(Number.isSafeInteger));
    const maxPages = all ? HISTORY_ALL_PAGE_GUARD : HISTORY_AFTER_PAGE_GUARD;
    for (let page = 0; page < maxPages && hasMore; page += 1) {
      const seqs = records.map((record) => record?.event?.seq).filter(Number.isSafeInteger);
      if (seqs.length === 0) break;
      const beforeSeq = Math.min(...seqs);
      if (beforeSeq <= 0) break;
      if (afterSeq !== null && beforeSeq <= afterSeq) break;
      if (!all && afterSeq === null && messages.length >= HISTORY_MIN_MESSAGES) break;
      const older = await controller.page({
        address: { kind: "session", sessionId },
        throughSeq: snapshot.cursor,
        beforeSeq,
        maxMessages: limit,
        turnWindow: TURN_WINDOW,
      }, pageSignal);
      const pageRecordsValue = Array.isArray(older?.records) ? older.records : [];
      const fresh = pageRecordsValue.filter((record) => {
        const seq = record?.event?.seq;
        return Number.isSafeInteger(seq) && !seen.has(seq);
      });
      if (fresh.length === 0) break;
      for (const record of fresh) seen.add(record?.event?.seq);
      records = [...fresh, ...records];
      messages = messagesFromSnapshot({ records });
      hasMore = older?.hasMore === true;
    }
    if (afterSeq !== null) {
      messages = messages.filter((message) => Number.isSafeInteger(message.seq) && message.seq > afterSeq);
    }
    return { messages, hasMore };
  }

  async streamEvents(req, res, sessionId, limit) {
    const controller = this.requireController();
    const abort = new AbortController();
    this.activeStreams.add(abort);
    const onClose = () => abort.abort();
    req.on("close", onClose);
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
      "x-accel-buffering": "no",
    });
    res.write(": connected\n\n");
    const heartbeat = setInterval(() => {
      if (!res.writableEnded) res.write(": ping\n\n");
    }, HEARTBEAT_MS);
    heartbeat.unref?.();
    const write = (event, data) => new Promise((resolve) => {
      if (res.writableEnded) return resolve();
      try {
        res.write("event: " + event + "\ndata: " + JSON.stringify(data) + "\n\n", () => resolve());
      } catch {
        resolve();
      }
    });
    try {
      await write("ready", { sessionId });
      const follow = controller.follow({
        address: { kind: "session", sessionId },
        maxMessages: limit,
        turnWindow: TURN_WINDOW,
        assistantStream: true,
      }, abort.signal);
      for await (const item of follow) {
        if (abort.signal.aborted) break;
        if (item?.type === "snapshot") {
          const expanded = await this.expandSnapshot(sessionId, item, limit, abort.signal);
          await write("snapshot", {
            sessionId,
            messages: expanded.messages ?? messagesFromSnapshot(expanded),
            hasMore: expanded.hasMore === true,
            cursor: expanded.cursor,
          });
          continue;
        }
        if (item?.type === "event") {
          const event = item.event;
          if (event?.type === "tool/call") {
            await write("tool_call", {
              turn: event.data?.turn,
              step: event.data?.step,
              callId: event.data?.callId,
              name: event.data?.name,
              detail: summarizeToolArguments(event.data?.name, event.data?.arguments),
            });
            continue;
          }
          if (event?.type === "tool/result") {
            const text = textOfContent(event.data?.message?.content);
            await write("tool_result", {
              turn: event.data?.turn,
              step: event.data?.step,
              callId: event.data?.message?.toolCallId,
              ok: event.data?.message?.isError !== true,
              text: text.slice(0, 300),
            });
            continue;
          }
          if (event?.type === "turn/end") {
            // The status row must stay for the whole turn, including the gaps
            // between steps where no assistant stream is open.
            await write("turn_end", {
              turn: event.data?.turn,
              reason: event.data?.reason?.kind ?? null,
            });
            continue;
          }
          const message = eventToMessage(event);
          if (message) await write("message", message);
          // Committed assistant messages carry the step's full reasoning even
          // when DSH does not stream reasoning-delta frames to this subscriber.
          // Send it as a block so the widget tail still has text to show.
          if (event.type === "assistant/message") {
            const reasoning = partsOfContent(event.data?.message?.content).reasoning;
            if (reasoning.trim()) {
              await write("reasoning_block", {
                turn: event.data?.turn ?? null,
                step: event.data?.step ?? null,
                text: reasoning,
              });
            }
          }
          continue;
        }
        if (item?.type !== "assistant-stream") continue;
        const frame = item.frame;
        if (!frame) continue;
        if (frame.type === "start") {
          await write("assistant_start", {
            attemptId: frame.attemptId,
            turn: frame.turn,
            step: frame.step,
            revision: frame.revision,
          });
          continue;
        }
        if (frame.type === "end") {
          await write("assistant_end", {
            attemptId: frame.attemptId,
            outcome: frame.outcome ?? null,
          });
          continue;
        }
        const chunk = frame.chunk;
        if (!chunk) continue;
        if (chunk.type === "text-delta" && typeof chunk.text === "string" && chunk.text) {
          await write("assistant_delta", {
            attemptId: frame.attemptId,
            turn: frame.turn,
            step: frame.step,
            index: chunk.index,
            text: chunk.text,
          });
        } else if (chunk.type === "reasoning-delta" && typeof chunk.text === "string" && chunk.text) {
          await write("reasoning_delta", {
            attemptId: frame.attemptId,
            turn: frame.turn,
            step: frame.step,
            index: chunk.index,
            text: chunk.text,
          });
        } else if (chunk.type === "block-end" && chunk.block?.type === "text" && typeof chunk.block.text === "string") {
          await write("assistant_block", {
            attemptId: frame.attemptId,
            turn: frame.turn,
            step: frame.step,
            index: chunk.index,
            text: chunk.block.text,
          });
        }
      }
    } catch (error) {
      if (!abort.signal.aborted) await write("error", errorBody(error));
    } finally {
      clearInterval(heartbeat);
      req.off("close", onClose);
      this.activeStreams.delete(abort);
      if (!res.writableEnded) res.end();
    }
  }
}

export const name = "dsh-widget-bridge";

function safeGet(ctx, service) {
  try {
    const value = ctx?.get?.(service);
    if (value) return value;
  } catch {}
  try {
    return ctx?.[service];
  } catch {
    return undefined;
  }
}

export function apply(ctx, rawConfig = {}) {
  const bridge = new WidgetBridge({
    host: rawConfig.host,
    port: rawConfig.port,
    discoveryPath: rawConfig.discoveryPath,
  });
  let disposed = false;
  let injectDispose;
  let started = false;
  const autoAttachOrphans = rawConfig.attachOrphans !== false;
  const start = (scoped) => {
    if (disposed || started) return;
    const scope = scoped ?? ctx;
    const controller = safeGet(scope, "sessionController");
    if (!controller) return;
    started = true;
    bridge.attach(controller, safeGet(scope, "workspaceRegistry") ?? null);
    void bridge
      .start()
      .then(async () => {
        if (!autoAttachOrphans || disposed) return undefined;
        // The Workspace registry may register slightly after the session
        // controller. Wait for it here instead of injecting it as a hard
        // dependency, so a missing registry can never keep the bridge offline.
        for (let attempt = 0; attempt < 40 && !disposed; attempt += 1) {
          const registry = safeGet(scope, "workspaceRegistry");
          if (registry) {
            bridge.attachRegistry(registry);
            break;
          }
          await new Promise((resolve) => {
            const timer = setTimeout(resolve, 250);
            if (typeof timer.unref === "function") timer.unref();
          });
        }
        if (disposed || !autoAttachOrphans) return undefined;
        return bridge.attachOrphanSessions().catch((error) => {
          console.error("[dsh-widget-bridge] orphan attach failed: " + String(error?.message ?? error));
        });
      })
      .catch((error) => {
        started = false;
        console.error("[dsh-widget-bridge] start failed: " + String(error?.message ?? error));
      });
  };
  const injectController = (names) => {
    try {
      return ctx.inject(names, (scoped) => start(scoped));
    } catch (error) {
      console.error("[dsh-widget-bridge] inject failed: " + String(error?.message ?? error));
      return undefined;
    }
  };
  if (safeGet(ctx, "sessionController")) {
    start();
  } else if (typeof ctx.inject === "function") {
    injectDispose = injectController(["sessionController"]);
  } else {
    console.error("[dsh-widget-bridge] sessionController is unavailable");
  }
  return () => {
    disposed = true;
    try { injectDispose?.(); } catch {}
    void bridge.stop();
  };
}