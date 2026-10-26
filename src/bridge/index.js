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
import { spawn } from "node:child_process";
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
import { homedir, networkInterfaces } from "node:os";
import { basename, dirname, join, sep } from "node:path";
import {
  AuditLog,
  DeviceStore,
  PAIRING_TTL_MS,
  PairingStore,
  RateLimiter,
  safeEqual,
} from "./security.js";
import { attachPanel } from "./panel.js";

const DEFAULT_DISCOVERY = join(homedir(), ".dsh", "widget-bridge.json");
const DEFAULT_DEVICES = join(homedir(), ".dsh", "widget-devices.json");
const DEFAULT_AUDIT = join(homedir(), ".dsh", "widget-audit.log");
// A tunnel URL changes every time the tunnel is re-created, so it cannot live in
// the launch config — that would mean restarting DSH after every reconnect. The
// bridge reads this file per request; `src/scripts/tunnel.sh` is its only writer.
const DEFAULT_PUBLIC_URL_FILE = join(homedir(), ".dsh", "widget-public-url");
const DEFAULT_LIMIT = 500;
const MAX_BODY_BYTES = 1024 * 1024;
// A pasted screenshot is base64 inside the prompt body, so this route needs a
// much larger ceiling than the control-plane routes.
const MAX_PROMPT_BODY_BYTES = 32 * 1024 * 1024;
const MAX_PROMPT_IMAGES = 8;
const HEARTBEAT_MS = 15000;
// Protocol version 2 adds capabilities to /v1/health, device pairing and
// per-device tokens. Version 1 clients only read ok/pid/version, so the bump
// stays backward compatible.
const BRIDGE_VERSION = 2;
const DEFAULT_RATE_PER_MINUTE = 240;
const GLOBAL_RATE_PER_MINUTE = 1200;
const AUTH_LOCK_MS = 5 * 60 * 1000;
const AUTH_FAILURES_BEFORE_LOCK = 10;
const CAPABILITIES = Object.freeze({
  protocolVersion: BRIDGE_VERSION,
  pairing: true,
  deviceRevoke: true,
  push: false,
  images: true,
  maxImages: MAX_PROMPT_IMAGES,
  reasoning: true,
  toolTrace: true,
  multiDevice: true,
  workspaces: true,
  archivedFilter: true,
  dshRestart: true,
});

const DSH_APP_PATH = "/Applications/DeepSeek Harness.app";
const DSH_EXECUTABLE_PATH = DSH_APP_PATH + "/Contents/MacOS/DeepSeek Harness";

/**
 * Quits and relaunches the DSH app that hosts this bridge.
 *
 * Measured on this machine (2026-10-26): SIGTERM on the main Electron process
 * (ppid 1) exits it in ~10s, and `open -a` brings the bridge back on the same
 * port ~4s later. The pid from /v1/health is the Host *subprocess*, so killing
 * that one leaves the window alive with no bridge — an apparent success that
 * restarts nothing. The script therefore matches ppid 1 and an exact command
 * line instead.
 *
 * It is spawned detached and unref'd: it has to outlive this process, and the
 * SIGTERM it sends must not reach the shell that sent it.
 */
// Launching the app from inside the DSH process tree does not work: this
// bridge SIGTERMs the app and LaunchServices then silently drops the relaunch
// request (exit 0, no process, not even a log line). Measured 2026-10-26: the
// same `open -n` from a launchd job brings it back in about a second. So submit
// a one-shot job that kills, waits, relaunches, and removes itself.
const RESTART_LABEL = "com.ryankiin.dshwidget.bridge-restart";
const RESTART_LOG = "/tmp/dsh-bridge-restart.log";

function restartDSHHost(log = () => {}) {
  const scriptPath = join("/tmp", "dsh-bridge-restart-" + randomUUID() + ".sh");
  const script = [
    "#!/bin/bash",
    "exec >> " + RESTART_LOG + " 2>&1",
    'echo "$(date \'+%H:%M:%S\') bridge restart start"',
    "EXE=" + JSON.stringify(DSH_EXECUTABLE_PATH),
    'main() { ps -Ao pid,ppid,command | awk -v exe="$EXE" \'$2 == 1 && substr($0, length($0) - length(exe) + 1) == exe { print $1; exit }\'; }',
    'P=$(main)',
    'echo "main=${P:-none}"',
    '[ -n "$P" ] && kill -TERM "$P"',
    'for i in $(seq 1 60); do sleep 0.5; [ -z "$(main)" ] && break; done',
    'echo "$(date \'+%H:%M:%S\') exited"',
    "sleep 2",
    "for r in 1 2 3; do",
    "  open -n -a " + JSON.stringify(DSH_APP_PATH),
    '  echo "$(date \'+%H:%M:%S\') open exit=$? round=$r"',
    "  N=",
    '  for i in $(seq 1 40); do sleep 0.5; N=$(main); [ -n "$N" ] && break; done',
    '  if [ -n "$N" ]; then echo "$(date \'+%H:%M:%S\') recovered pid=$N round=$r"; launchctl remove ' +
      RESTART_LABEL + '; rm -f "$0"; exit 0; fi',
    "done",
    'echo "$(date \'+%H:%M:%S\') FAILED after 3 rounds"',
    "launchctl remove " + RESTART_LABEL,
    'rm -f "$0"',
  ].join("\n");
  try {
    writeFileSync(scriptPath, script, { mode: 0o700 });
  } catch (error) {
    log("dsh restart script failed: " + String(error?.message ?? error));
    return;
  }
  try {
    spawn("/bin/launchctl", ["remove", RESTART_LABEL], { stdio: "ignore" }).on("error", () => {});
    spawn("/bin/launchctl", ["submit", "-l", RESTART_LABEL, "--", "/bin/bash", scriptPath], {
      stdio: "ignore",
    }).on("error", (error) => log("dsh restart submit failed: " + String(error?.message ?? error)));
  } catch (error) {
    log("dsh restart submit failed: " + String(error?.message ?? error));
  }
}

// maxMessages counts event records, not chat messages. Ask DSH for both a
// bounded event window and a minimum conversation window so opening a long
// session still shows a few rounds instead of only the latest tool events.
const TURN_WINDOW = Object.freeze({ minMessages: 20, minTurns: 2 });// Sessions created before workspaces existed (or by an older host) carry no
// membership. Hiding them would make them unreachable from the phone, so they
// surface under one synthetic bucket instead.
const UNGROUPED_WORKSPACE_ID = "__ungrouped";

/**
 * DSH rejects a request whose turnWindow.minMessages exceeds maxMessages, so a
 * caller asking for fewer than 20 records narrows the turn window instead of
 * being turned into a 400.
 */
function turnWindowFor(limit) {
  if (!Number.isSafeInteger(limit) || limit <= 0 || limit >= TURN_WINDOW.minMessages) {
    return TURN_WINDOW;
  }
  return { ...TURN_WINDOW, minMessages: limit };
}
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

function clientIp(req) {
  const forwarded = req.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.trim()) {
    // A reverse proxy (Tailscale Funnel) reports the real client here. The
    // value is advisory: it only feeds rate limiting, never authorization.
    return forwarded.split(",")[0].trim().slice(0, 64);
  }
  return String(req.socket?.remoteAddress ?? "");
}

function errorBody(error) {
  const code = typeof error?.code === "string" ? error.code : "gateway/internal";
  const message = error instanceof Error ? error.message : String(error);
  return { error: { code, message } };
}

function statusFor(error) {
  const code = typeof error?.code === "string" ? error.code : "";
  if (code === "gateway/bad-request" || code.endsWith("-invalid")) return 400;
  if (code === "pairing/not-started" || code === "pairing/expired") return 400;
  if (code === "pairing/invalid-code" || code === "gateway/unauthorized") return 401;
  if (code === "gateway/forbidden") return 403;
  if (code === "gateway/not-found") return 404;
  if (code === "session/not-found" || code === "subagent/not-found" || code === "workspace/not-found") return 404;
  if (code === "session/agent-busy" || code === "session/writer-held") return 409;
  if (code === "pairing/too-many-attempts" || code === "gateway/rate-limited" || code === "gateway/auth-locked") return 429;
  if (code === "gateway/not-implemented") return 501;
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
      // Committed messages keep the step's whole reasoning; the client shows
      // it above the bubble, so history-only turns read like live ones.
      reasoning: parts.reasoning,
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

function normalizeWorkspace(workspace) {
  const path = typeof workspace.path === "string" ? workspace.path : null;
  const rawTitle = typeof workspace.title === "string" ? workspace.title.trim() : "";
  return {
    id: String(workspace.id),
    title: rawTitle || (path ? basename(path) : String(workspace.id)),
    path,
    sessionCount: Array.isArray(workspace.sessionIds) ? workspace.sessionIds.length : 0,
    updatedAt: Number(workspace.updatedAt) || 0,
  };
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
    // Delegated sessions belong to a parent turn and cannot be opened on the
    // phone (their history answers 409), so the client must be able to tell
    // them apart from ordinary ones.
    origin: typeof row.origin === "string" ? row.origin : null,
    parentSessionId:
      typeof row.parentSessionId === "string"
        ? row.parentSessionId
        : typeof row.parentSession === "string"
          ? row.parentSession
          : null,
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

/** Current tunnel URL left on disk by `tunnel.sh`, if any. */
function runtimePublicUrl(path) {
  try {
    const raw = readFileSync(path, "utf8").trim();
    return raw.length ? raw : null;
  } catch {
    return null;
  }
}

/** LAN IPv4 candidates a phone could dial, in interface order. */
function lanAddresses(port) {
  const urls = [];
  for (const list of Object.values(networkInterfaces())) {
    for (const net of list ?? []) {
      if (net.family !== "IPv4" || net.internal) continue;
      if (net.address.startsWith("169.254.")) continue;
      urls.push("http://" + net.address + ":" + String(port));
    }
  }
  return urls;
}

/**
 * Payload for the QR code the desktop widget shows. A custom scheme keeps the
 * code useless to random QR scanners; the phone app parses it and pre-fills
 * both the base URL and the pairing code.
 */
function pairingURI(base, code, addrs) {
  const params = new URLSearchParams({ v: "1", u: base, c: code });
  if (addrs.length > 1) params.set("a", addrs.join(","));
  return "dshwidget://pair?" + params.toString();
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
    // Loopback mode can rely on the host token alone. Once the bridge is
    // reachable from the network, each client needs its own revocable
    // credential, so pairing and per-device tokens are always available.
    this.publicUrl =
      options.publicUrl ?? process.env.DSH_BRIDGE_PUBLIC_URL ?? null;
    this.publicUrlFile = options.publicUrlFile ?? DEFAULT_PUBLIC_URL_FILE;
    this.publicMode =
      options.publicMode ??
      (this.host !== "127.0.0.1" && this.host !== "localhost" && this.host !== "::1");
    this.pairing = new PairingStore({ ttlMs: options.pairingTtlMs ?? PAIRING_TTL_MS });
    this.devices = new DeviceStore({ path: options.devicesPath ?? DEFAULT_DEVICES });
    this.audit = new AuditLog({ path: options.auditPath ?? DEFAULT_AUDIT });
    this.requestLimiter = new RateLimiter({
      windowMs: 60_000,
      max: options.requestsPerMinute ?? DEFAULT_RATE_PER_MINUTE,
    });
    this.globalLimiter = new RateLimiter({
      windowMs: 60_000,
      max: options.globalRequestsPerMinute ?? GLOBAL_RATE_PER_MINUTE,
    });
    this.authLimiter = new RateLimiter({
      windowMs: AUTH_LOCK_MS,
      max: options.authFailuresBeforeLock ?? AUTH_FAILURES_BEFORE_LOCK,
    });
    this.server = null;
    this.started = false;
    this.stopping = false;
    this.activeStreams = new Set();
    // sessionId → 这一轮正在产生的思考。DSH 只把 reasoning-delta 推给当时的
    // 订阅者，手机切后台/退会话错过就再也拿不回来；重连时先回放这一段。
    this.liveReasoning = new Map();
    // sessionId → 上一轮观察到的 running。把「在跑 → 不跑」翻成一条未读，
    // 手机被系统回收后重启时，这份记录是唯一还记得那次结束的地方。
    this.runningSnapshot = new Map();
    this.endedAt = new Map();
    this.transitionTimer = null;
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

  /** 新一轮开始：换 turn/step/attempt 就重置缓冲，同一轮内重复收到 start 不重置。 */
  beginLiveReasoning(sessionId, turn, step, attemptId) {
    const key = String(sessionId);
    const current = this.liveReasoning.get(key);
    if (
      current &&
      current.turn === (turn ?? null) &&
      current.step === (step ?? null) &&
      current.attemptId === (attemptId ?? null)
    ) {
      return;
    }
    this.liveReasoning.set(key, {
      turn: turn ?? null,
      step: step ?? null,
      attemptId: attemptId ?? null,
      text: "",
      startedAt: Date.now(),
      seen: new Set(),
    });
  }

  /** 逐帧累积。同一会话可能有多个订阅者，靠 attemptId + index 去重。 */
  appendLiveReasoning(sessionId, frame, chunk) {
    const key = String(sessionId);
    let live = this.liveReasoning.get(key);
    if (
      !live ||
      live.turn !== (frame.turn ?? null) ||
      live.step !== (frame.step ?? null)
    ) {
      this.beginLiveReasoning(sessionId, frame.turn, frame.step, frame.attemptId);
      live = this.liveReasoning.get(key);
    }
    if (!live) return;
    const mark = `${frame.attemptId ?? ""}:${chunk.index ?? live.text.length}`;
    if (live.seen.has(mark)) return; // 第二个订阅者重复收到同一段
    live.seen.add(mark);
    live.text += chunk.text;
  }

  /** 落库后的整段 reasoning 比逐帧拼接权威，直接覆盖。 */
  replaceLiveReasoning(sessionId, turn, step, text) {
    const live = this.liveReasoning.get(String(sessionId));
    if (!live) return;
    if (turn != null && live.turn != null && turn !== live.turn) return;
    live.text = text;
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

  /**
   * 记录每个会话「从跑到不跑」的时刻。手机端自己也会翻转，但 App 被系统回收
   * 后重启就丢了基线；这份由 bridge 常驻维护的记录是补灯的唯一来源。
   * 子代理会话不参与：手机列表里根本不显示它们。
   */
  async trackRunningTransitions() {
    if (!this.controller) return;
    let rows;
    try {
      rows = await this.requireController().list({}, undefined);
    } catch {
      return;
    }
    const current = new Map();
    for (const row of rows?.items ?? []) {
      if (row?.origin === "subagent") continue;
      // controller.list 的行用 sessionId，不是 id。
      const id = String(row?.sessionId ?? row?.id);
      current.set(id, row?.running === true);
    }
    const now = Date.now();
    for (const [id, wasRunning] of this.runningSnapshot) {
      if (wasRunning && current.get(id) === false) this.endedAt.set(id, now);
    }
    for (const [id, isRunning] of current) {
      if (isRunning && this.endedAt.has(id)) this.endedAt.delete(id);
    }
    this.runningSnapshot = current;
  }

  startTransitionWatcher() {
    if (this.transitionTimer) return;
    void this.trackRunningTransitions();
    this.transitionTimer = setInterval(() => {
      void this.trackRunningTransitions();
    }, 5000);
    // 别让这个定时器拖住进程退出。
    this.transitionTimer.unref?.();
  }

  stopTransitionWatcher() {
    if (!this.transitionTimer) return;
    clearInterval(this.transitionTimer);
    this.transitionTimer = null;
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

  /** sessionId -> workspaceId, built from the registry's membership lists. */
  sessionWorkspaceIndex() {
    const index = new Map();
    if (!this.registry || typeof this.registry.list !== "function") return index;
    try {
      for (const workspace of this.registry.list()) {
        for (const sessionId of workspace.sessionIds ?? []) {
          index.set(String(sessionId), String(workspace.id));
        }
      }
    } catch {
      return index;
    }
    return index;
  }

  archivedSessionSet() {
    if (!this.registry) return new Set();
    try {
      return new Set((this.registry.archivedSessionIds ?? []).map(String));
    } catch {
      return new Set();
    }
  }

  /** Live sessions that no workspace claims; they get the "未分组" bucket. */
  async ungroupedSessions() {
    try {
      const rows = await this.requireController().list({}, undefined);
      const index = this.sessionWorkspaceIndex();
      const archived = this.archivedSessionSet();
      return (rows?.items ?? [])
        .map((row) => normalizeSession(row))
        .filter((session) => !archived.has(String(session.id)))
        .filter((session) => session.origin !== "subagent")
        // 0 消息的空会话在手机上点开就是一页白，默认不列。
        .filter((session) => session.blank !== true)
        .filter((session) => !index.get(String(session.id)));
    } catch {
      return [];
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
      publicMode: this.publicMode,
      capabilities: CAPABILITIES,
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
    const listen = (port) =>
      new Promise((resolve, reject) => {
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
        this.server.listen(port, this.host);
      });
    try {
      await listen(this.port);
    } catch (error) {
      // A fixed port that is already taken (second Host instance, another
      // process) must never take the bridge offline: fall back to an
      // ephemeral port and let discovery carry the real value.
      if (this.port === 0 || error?.code !== "EADDRINUSE") throw error;
      this.logger.error(
        "[dsh-widget-bridge] port " + String(this.port) + " is busy, falling back to an ephemeral port",
      );
      try {
        this.server.close();
      } catch {
        /* not listening yet; nothing to close */
      }
      await listen(0);
    }
    const address = this.server.address();
    if (!address || typeof address === "string") throw new Error("bridge did not bind a TCP port");
    this.port = address.port;
    this.started = true;
    this.writeDiscovery();
    this.startTransitionWatcher();
    this.logger.log("[dsh-widget-bridge] listening on " + this.host + ":" + String(this.port));
    return this;
  }

  async stop() {
    this.stopping = true;
    this.stopTransitionWatcher();
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

  /** Resolve the caller: the host token, or one paired device's token. */
  identity(req) {
    if (req.headers.origin) return null;
    const header = req.headers.authorization;
    if (typeof header !== "string" || !header.startsWith("Bearer ")) return null;
    const provided = header.slice("Bearer ".length).trim();
    if (!provided) return null;
    if (safeEqual(provided, this.token)) return { primary: true, device: null };
    const device = this.devices.verify(provided);
    return device ? { primary: false, device } : null;
  }

  authorized(req) {
    return this.identity(req) !== null;
  }

  /** Device management always requires the host token, never a device token. */
  requirePrimary(identity) {
    if (!identity) {
      const error = new Error("widget token required");
      error.code = "gateway/unauthorized";
      throw error;
    }
    if (!identity.primary) {
      const error = new Error("host token required");
      error.code = "gateway/forbidden";
      throw error;
    }
  }

  /**
   * Second half of pairing: the code proves the user was in front of the host,
   * and this call mints that device's own token exactly once.
   */
  async claimPairing(req, res, ip) {
    const body = await readBody(req);
    const result = this.pairing.claim(body.code);
    if (!result.ok) {
      const error = new Error("pairing failed");
      error.code = result.error;
      throw error;
    }
    const created = this.devices.addDevice({ name: body.name, ip });
    this.audit.record({
      event: "pair-claim",
      ip,
      deviceId: created.device.id,
      label: created.device.name,
    });
    json(res, 200, { deviceToken: created.token, device: created.device });
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
    const ip = clientIp(req);
    const startedAt = Date.now();
    const identity = this.identity(req);
    res.on("close", () => {
      this.audit.record({
        event: "request",
        ip,
        method: req.method,
        path: pathname,
        status: res.statusCode,
        ms: Date.now() - startedAt,
        deviceId: identity?.device?.id ?? null,
        primary: identity?.primary === true,
      });
    });

    if (!pathname.startsWith("/v1/")) {
      json(res, 404, { error: { code: "gateway/not-found", message: "not found" } });
      return;
    }

    const perIp = this.requestLimiter.hit(ip);
    const global = this.globalLimiter.hit("all");
    if (!perIp.allowed || !global.allowed) {
      const retryAfterMs = Math.max(perIp.retryAfterMs, global.retryAfterMs);
      res.setHeader("retry-after", String(Math.max(1, Math.ceil(retryAfterMs / 1000))));
      json(res, 429, { error: { code: "gateway/rate-limited", message: "too many requests" } });
      return;
    }

    // Health is public on purpose: a client must be able to learn the protocol
    // version and capabilities before it holds any token.
    if (pathname === "/v1/health" && req.method === "GET") {
      json(res, 200, {
        ok: true,
        pid: process.pid,
        version: BRIDGE_VERSION,
        publicMode: this.publicMode,
        capabilities: CAPABILITIES,
      });
      return;
    }

    // The pairing code is itself the credential for the claim call, so it is
    // the one state-changing route without a token: rate limited above and
    // burned after ten wrong guesses.
    if (pathname === "/v1/pair/claim" && req.method === "POST") {
      await this.claimPairing(req, res, ip);
      return;
    }
    if (pathname === "/v1/pair/start" && req.method === "POST") {
      this.requirePrimary(identity);
      const body = await readBody(req);
      // The QR payload carries every reachable base URL, so the phone keeps
      // working when it leaves the LAN and falls back to the tunnel.
      const ticket = this.pairingTicket();
      this.audit.record({
        event: "pair-start",
        ip,
        label: typeof body.label === "string" ? body.label.slice(0, 60) : null,
        expiresAt: ticket.expiresAt,
      });
      json(res, 200, ticket);
      return;
    }
    if (pathname === "/v1/devices" && req.method === "GET") {
      this.requirePrimary(identity);
      json(res, 200, { devices: this.devices.list() });
      return;
    }
    const deviceMatch = /^\/v1\/devices\/([^/]+)$/u.exec(pathname);
    if (deviceMatch && req.method === "DELETE") {
      this.requirePrimary(identity);
      const deviceId = decodeURIComponent(deviceMatch[1]);
      if (!this.devices.revoke(deviceId)) {
        const error = new Error("device not found");
        error.code = "gateway/not-found";
        throw error;
      }
      this.audit.record({ event: "device-revoke", ip, deviceId });
      json(res, 200, { deviceId, revoked: true });
      return;
    }
    if (pathname === "/v1/push/register" && req.method === "POST") {
      json(res, 501, {
        error: { code: "gateway/not-implemented", message: "push registration is not implemented yet" },
      });
      return;
    }

    if (!identity) {
      const gate = this.authLimiter.hit(ip);
      if (!gate.allowed) {
        res.setHeader("retry-after", String(Math.max(1, Math.ceil(gate.retryAfterMs / 1000))));
        json(res, 429, { error: { code: "gateway/auth-locked", message: "too many failed attempts" } });
        return;
      }
      json(res, 401, { error: { code: "gateway/unauthorized", message: "widget token required" } });
      return;
    }
    this.authLimiter.reset(ip);

    if (pathname === "/v1/dsh/restart" && req.method === "POST") {
      // Answer before acting: this bridge runs inside the process the script is
      // about to SIGTERM. A full restart measured ~15s end to end, so the client
      // polls /v1/health instead of holding this response open.
      json(res, 200, { ok: true, restarting: true });
      this.audit.record({ event: "dsh-restart", ip, deviceId: identity?.device?.id ?? null });
      setImmediate(() => {
        restartDSHHost((message) => console.error("[dsh-widget-bridge] " + message));
      });
      return;
    }

    if (pathname === "/v1/endpoints" && req.method === "GET") {
      // 手机在局域网里连上时顺手把候选地址刷新一次：quick tunnel 重建后
      // 域名会变，不然出门就只能重新扫一次配对码。
      json(res, 200, { addrs: this.pairCandidates(), updatedAt: new Date().toISOString() });
      return;
    }

    if (pathname.startsWith("/v1/attachments/") && req.method === "GET") {
      await this.serveAttachment(res, pathname.slice("/v1/attachments/".length));
      return;
    }

    if (pathname === "/v1/workspaces" && req.method === "GET") {
      // 计数必须与 /v1/sessions 同口径：子代理、空会话、归档都不算。
      // 之前按 workspace.sessionIds 的长度算，但那份列表里还留着已归档会话和
      // 查不到的旧 id —— 实测工作区显示 13 条、点开只有 5 条，就是对不上。
      const perWorkspace = new Map();
      try {
        const rows = await this.requireController().list({}, undefined);
        const archived = this.archivedSessionSet();
        const index = this.sessionWorkspaceIndex();
        for (const row of rows?.items ?? []) {
          const id = String(row?.sessionId ?? row?.id);
          if (row?.origin === "subagent") continue;
          if (row?.blank === true) continue;
          if (archived.has(id)) continue;
          const workspaceId = index.get(id);
          if (!workspaceId) continue;
          const bucket = perWorkspace.get(workspaceId) ?? { count: 0, running: 0 };
          bucket.count += 1;
          if (row?.running === true) bucket.running += 1;
          perWorkspace.set(workspaceId, bucket);
        }
      } catch {
        // A paused host should still list workspaces; the lamps just stay off.
      }
      const list =
        this.registry && typeof this.registry.list === "function" ? this.registry.list() : [];
      const workspaces = list
        .map((workspace) => {
          const normalized = normalizeWorkspace(workspace);
          const bucket = perWorkspace.get(String(workspace.id)) ?? { count: 0, running: 0 };
          normalized.sessionCount = bucket.count;
          normalized.runningCount = bucket.running;
          return normalized;
        })
        .sort((a, b) => b.updatedAt - a.updatedAt);
      const ungrouped = await this.ungroupedSessions();
      if (ungrouped.length > 0) {
        workspaces.push({
          id: UNGROUPED_WORKSPACE_ID,
          title: "未分组",
          path: "",
          sessionCount: ungrouped.length,
          runningCount: ungrouped.filter((session) => session.running === true).length,
          updatedAt: Math.max(...ungrouped.map((session) => session.updatedAt || 0)),
        });
      }
      json(res, 200, { workspaces });
      return;
    }

    if (pathname === "/v1/sessions" && req.method === "GET") {
      const rows = await this.requireController().list({}, undefined);
      const archived = this.archivedSessionSet();
      const includeArchived = ["1", "true"].includes(
        String(url.searchParams.get("includeArchived") ?? "").toLowerCase(),
      );
      const includeSubagents = ["1", "true"].includes(
        String(url.searchParams.get("includeSubagents") ?? "").toLowerCase(),
      );
      const includeBlank = ["1", "true"].includes(
        String(url.searchParams.get("includeBlank") ?? "").toLowerCase(),
      );
      const workspaceFilter = url.searchParams.get("workspaceId");
      const index = this.sessionWorkspaceIndex();
      let sessions = (rows?.items ?? []).map((row) => {
        const session = normalizeSession(row);
        session.workspaceId = index.get(String(session.id)) ?? null;
        session.archived = archived.has(String(session.id));
        // 这一轮结束的时刻由 bridge 常驻记录：App 被系统回收后重启，
        // 本地基线没了，只能靠它把黄灯补回来。已读走 /read 清掉。
        session.endedAt = this.endedAt.get(String(session.id)) ?? null;
        return session;
      });
      // Archived sessions are hidden by default: they are dead ends on a phone.
      if (!includeArchived) sessions = sessions.filter((session) => session.archived !== true);
      // Subagent sessions are delegated work of another turn: their history only
      // opens through the parent, so listing them on the phone is a dead end.
      if (!includeSubagents) sessions = sessions.filter((session) => session.origin !== "subagent");
      // 0 消息的空会话点开就是一页白，默认不列（手机端每次新建都会留下一条）。
      if (!includeBlank) sessions = sessions.filter((session) => session.blank !== true);
      if (workspaceFilter === UNGROUPED_WORKSPACE_ID) {
        sessions = sessions.filter((session) => !session.workspaceId);
      } else if (workspaceFilter) {
        sessions = sessions.filter((session) => session.workspaceId === workspaceFilter);
      }
      json(res, 200, { sessions });
      return;
    }

    // 看过就把未读清掉。手机进入/离开会话时调用；bridge 这条记录也要清，
    // 否则 App 重启后会把已经看过的会话重新点亮。
    const readMatch = /^\/v1\/sessions\/([^/]+)\/read$/.exec(pathname);
    if (readMatch && req.method === "POST") {
      this.endedAt.delete(decodeURIComponent(readMatch[1]));
      json(res, 200, { ok: true });
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
        // before=<seq> pages further back than a client's oldest message; the
        // tail snapshot alone cannot serve a long session's scrollback.
        const beforeValue = url.searchParams.get("before");
        const beforeSeq = beforeValue === null ? null : parseAfterSeq(beforeValue);
        if (all || afterSeq !== null || beforeSeq !== null) {
          const page = await this.readHistory(sessionId, limit, {
            all: all && afterSeq === null && beforeSeq === null,
            afterSeq,
            beforeSeq,
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
        // A bare page request is the widget's first paint: the most recent
        // window plus the sequence bounds, so the client can tell "window" from
        // "everything" and ask for the page above it.
        const window = await this.readWindow(sessionId, limit);
        const pageSeqs = window.messages.map((message) => message.seq).filter(Number.isSafeInteger);
        json(res, 200, {
          sessionId,
          messages: window.messages,
          hasMore: window.hasMore,
          oldestSeq: pageSeqs.length ? Math.min(...pageSeqs) : null,
          newestSeq: pageSeqs.length ? Math.max(...pageSeqs) : null,
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
        turnWindow: turnWindowFor(limit),
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
      turnWindow: turnWindowFor(limit),
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
   * The widget's first paint: roughly the last `limit` messages, walking back
   * from the tail. Reading the tail snapshot alone returned a handful of
   * bubbles, so the window has to fill itself before it is served.
   */
  async readWindow(sessionId, limit) {
    const controller = this.requireController();
    const pageSignal = new AbortController().signal;
    const snapshot = await this.readTailSnapshot(sessionId, limit);
    let records = Array.isArray(snapshot?.records) ? snapshot.records.slice() : [];
    let messages = messagesFromSnapshot({ records });
    let hasMore = snapshot?.hasMore === true;
    const seen = new Set(records.map((record) => record?.event?.seq).filter(Number.isSafeInteger));
    for (let page = 0; page < HISTORY_ALL_PAGE_GUARD && hasMore && messages.length < limit; page += 1) {
      const seqs = records.map((record) => record?.event?.seq).filter(Number.isSafeInteger);
      if (seqs.length === 0) break;
      const oldestSeq = Math.min(...seqs);
      if (oldestSeq <= 0) break;
      const older = await controller.page({
        address: { kind: "session", sessionId },
        throughSeq: snapshot.cursor,
        beforeSeq: oldestSeq,
        maxMessages: limit,
        turnWindow: turnWindowFor(limit),
      }, pageSignal);
      const fresh = (Array.isArray(older?.records) ? older.records : []).filter((record) => {
        const seq = record?.event?.seq;
        return Number.isSafeInteger(seq) && !seen.has(seq);
      });
      if (fresh.length === 0) break;
      for (const record of fresh) seen.add(record?.event?.seq);
      records = [...fresh, ...records];
      messages = messagesFromSnapshot({ records });
      hasMore = older?.hasMore === true;
    }
    return { messages, hasMore };
  }

  /**
   * Full import or incremental catch-up. DSH only pages backwards, so start
   * from the tail and walk back until the requested boundary (afterSeq) is
   * covered, or until the caller asked for everything. The page guard keeps a
   * corrupt/looping Host from turning this into an unbounded request.
   */
  async readHistory(sessionId, limit, { all = false, afterSeq = null, beforeSeq = null } = {}) {
    const controller = this.requireController();
    const pageSignal = new AbortController().signal;
    const snapshot = await this.readTailSnapshot(sessionId, limit);
    let records = Array.isArray(snapshot?.records) ? snapshot.records.slice() : [];
    let messages = messagesFromSnapshot({ records });
    let hasMore = snapshot?.hasMore === true;
    const seen = new Set(records.map((record) => record?.event?.seq).filter(Number.isSafeInteger));
    const maxPages = all || beforeSeq !== null ? HISTORY_ALL_PAGE_GUARD : HISTORY_AFTER_PAGE_GUARD;
    const olderThan = (seq) => messages.filter((message) => Number.isSafeInteger(message.seq) && message.seq < seq);
    for (let page = 0; page < maxPages && hasMore; page += 1) {
      // Walking back for a client's scrollback stops as soon as one page of
      // messages older than its oldest seq has been collected.
      if (beforeSeq !== null && olderThan(beforeSeq).length >= limit) break;
      const seqs = records.map((record) => record?.event?.seq).filter(Number.isSafeInteger);
      if (seqs.length === 0) break;
      const oldestSeq = Math.min(...seqs);
      if (oldestSeq <= 0) break;
      if (afterSeq !== null && oldestSeq <= afterSeq) break;
      if (!all && afterSeq === null && beforeSeq === null && messages.length >= HISTORY_MIN_MESSAGES) break;
      const older = await controller.page({
        address: { kind: "session", sessionId },
        throughSeq: snapshot.cursor,
        beforeSeq: oldestSeq,
        maxMessages: limit,
        turnWindow: turnWindowFor(limit),
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
    if (beforeSeq !== null) {
      const older = olderThan(beforeSeq);
      return { messages: older.slice(-limit), hasMore: older.length > limit || hasMore };
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
    // 每个事件带单调 id，客户端据此实现 Last-Event-ID 续传。注意：id 只在
    // 单条连接内有效，跨连接续传需要全局事件号（云网关阶段再补）。
    let eventSeq = 0;
    const resumeFrom = String(req.headers["last-event-id"] ?? "").trim();
    if (resumeFrom) {
      this.logger?.info?.("[dsh-widget-bridge] stream resume requested from " + resumeFrom);
    }
    const write = (event, data) => new Promise((resolve) => {
      if (res.writableEnded) return resolve();
      try {
        eventSeq += 1;
        res.write(
          "id: " + eventSeq + "\nevent: " + event + "\ndata: " + JSON.stringify(data) + "\n\n",
          () => resolve()
        );
      } catch {
        resolve();
      }
    });
    try {
      // ready 带上服务端此刻的 running：客户端断线、切后台或切走会话都可能
      // 错过 turn_end，重连后只能靠这个字段把状态行纠正回来，否则会永远
      // 停在「思考中」。
      let running = null;
      try {
        const rows = await controller.list({}, undefined);
        const row = (rows?.items ?? []).find(
          (item) => String(item?.sessionId) === String(sessionId),
        );
        if (row) running = row.running === true;
      } catch {
        running = null;
      }
      await write("ready", { sessionId, running });
      // 服务端还在跑、而这一轮已经吐过思考：先把缓冲回放给刚连上的客户端，
      // 否则状态行是一个空框，计时还得从 0 再算一遍。
      if (running !== false) {
        const live = this.liveReasoning.get(String(sessionId));
        if (live?.text?.trim()) {
          await write("reasoning_replay", {
            turn: live.turn,
            step: live.step,
            text: live.text,
            startedAt: live.startedAt,
          });
        }
      }
      const follow = controller.follow({
        address: { kind: "session", sessionId },
        maxMessages: limit,
        turnWindow: turnWindowFor(limit),
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
            this.liveReasoning.delete(String(sessionId));
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
              // 落库后的整段比逐帧拼接更权威，覆盖缓冲。
              this.replaceLiveReasoning(sessionId, event.data?.turn, event.data?.step, reasoning);
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
          this.beginLiveReasoning(sessionId, frame.turn, frame.step, frame.attemptId);
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
          this.appendLiveReasoning(sessionId, frame, chunk);
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

  /**
   * Every URL a pairing client could use, LAN first, then the public tunnel.
   * The desktop widget puts the first one in the QR payload and lists the rest
   * so a phone that scanned at home still works on cellular.
   */
  pairCandidates() {
    const urls = lanAddresses(this.port);
    // A live tunnel URL on disk wins over the launch config: the file is
    // rewritten on every reconnect, whereas the config would go stale by design.
    const publicUrl = runtimePublicUrl(this.publicUrlFile) ?? this.publicUrl;
    if (publicUrl) urls.push(publicUrl.replace(/\/+$/u, ""));
    if (!urls.length) urls.push("http://127.0.0.1:" + String(this.port));
    return urls;
  }

  /**
   * Issue one pairing ticket and its QR payload.
   *
   * The desktop app, `/v1/pair/start` and the settings panel all hand a phone
   * the same thing, so the ticket is built in one place: a fresh code, every
   * reachable base URL (LAN first, tunnel last) and the custom-scheme URI that
   * encodes both.
   * @returns the ticket fields, the address list, and the pairing URI.
   */
  pairingTicket() {
    const ticket = this.pairing.start();
    const addrs = this.pairCandidates();
    return { ...ticket, addrs, uri: pairingURI(addrs[0], ticket.code, addrs) };
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
    publicMode: rawConfig.publicMode,
    publicUrl: rawConfig.publicUrl,
    devicesPath: rawConfig.devicesPath,
    auditPath: rawConfig.auditPath,
    pairingTtlMs: rawConfig.pairingTtlMs,
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
  // The settings panel rides on the DSH web host, not on the bridge listener:
  // the bridge rejects browser-originated requests, so the panel reads this
  // live instance instead and no token is ever handed to a page.
  let panelDispose;
  try {
    if (typeof ctx.inject === "function") {
      panelDispose = ctx.inject(["webServer", "connection"], (scoped) =>
        attachPanel(bridge, scoped, (message) => console.error("[dsh-widget-bridge] " + message)),
      );
    }
  } catch (error) {
    console.error("[dsh-widget-bridge] panel inject failed: " + String(error?.message ?? error));
  }
  return () => {
    disposed = true;
    try { injectDispose?.(); } catch {}
    try { panelDispose?.(); } catch {}
    void bridge.stop();
  };
}