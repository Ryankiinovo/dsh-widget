import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WidgetBridge, apply } from "./index.js";

const dir = mkdtempSync(join(tmpdir(), "dsh-widget-bridge-"));
const discoveryPath = join(dir, "bridge.json");
const token = "test-token-0123456789";

const events = [
  { type: "event", event: { type: "user/message", seq: 1, time: 1, data: { source: { kind: "user" }, content: [{ type: "text", text: "你好" }] } } },
  { type: "event", event: { type: "assistant/message", seq: 2, time: 2, data: { turn: 1, step: 1, message: { content: [{ type: "text", text: "你好，我在。" }] } } } },
];
const olderEvent = {
  type: "event",
  event: {
    type: "user/message",
    seq: 0,
    time: 0,
    data: { source: { kind: "user" }, content: [{ type: "text", text: "更早的消息" }] },
  },
};

let lastCreateRequest = null;
let lastPromptContent = null;
const controller = {
  async list() {
    return {
      items: [
        { sessionId: "session-abc", cwd: "/tmp/project", updatedAt: 123, running: false, blank: false },
        { sessionId: "session-orphan", cwd: "/tmp/other", updatedAt: 120, running: false, blank: false },
      ],
    };
  },
  async create(request) {
    lastCreateRequest = request;
    return { sessionId: "session-new", cwd: request.cwd };
  },
  async prompt(request, signal) {
    assert.equal(request.sessionId, "session-abc");
    assert.equal(request.mode, "queue");
    // DSH admits images itself from encoded parts; an already-resolved
    // attachment block makes its admission throw, which it reports as
    // session/agent-busy.
    for (const part of request.content) {
      if (part.type === "image" && (typeof part.data !== "string" || part.attachment !== undefined)) {
        const error = new Error("prompt rejected");
        error.code = "session/agent-busy";
        throw error;
      }
    }
    lastPromptContent = request.content;
    const textPart = request.content.find((part) => part.type === "text");
    if (textPart) assert.equal(textPart.text, "测试");
    // DSH calls signal.throwIfAborted() at prompt admission; a missing signal
    // used to surface as a 500 gateway/internal error.
    assert.equal(typeof signal?.throwIfAborted, "function");
    assert.equal(signal.aborted, false);
    return { accepted: true };
  },
  async cancel() {
    return { cancelled: true };
  },
  async page(request, signal) {
    assert.equal(typeof signal?.throwIfAborted, "function");
    if (request.address.sessionId === "session-old" && request.beforeSeq === 1) {
      return { records: [olderEvent], hasMore: false };
    }
    return { records: [], hasMore: false };
  },
  async *follow(request, signal) {
    assert.equal(typeof signal?.throwIfAborted, "function");
    // DSH rejects a window whose minimum exceeds the record budget; a caller
    // asking for fewer than 20 records must have it narrowed, not rejected.
    assert.ok(
      request.turnWindow.minMessages <= request.maxMessages,
      "turnWindow.minMessages must not exceed maxMessages"
    );
    if (request.address.sessionId === "session-empty") {
      // A brand-new session can finish its follow iterator without any
      // snapshot. The bridge must read that as empty history, not a 500.
      return;
    }
    if (request.address.sessionId === "session-old") {
      if (request.maxMessages === 3) {
        assert.deepEqual(request.turnWindow, { minMessages: 3, minTurns: 2 });
      }
      yield { type: "snapshot", records: events, hasMore: true, cursor: 2 };
      return;
    }
    assert.equal(request.address.sessionId, "session-abc");
    assert.deepEqual(request.turnWindow, { minMessages: 20, minTurns: 2 });
    yield { type: "snapshot", records: events, hasMore: false, cursor: 2 };
    yield { type: "assistant-stream", frame: { type: "start", attemptId: "a1", turn: 1, step: 1, revision: 1 } };
    yield { type: "assistant-stream", frame: { type: "chunk", attemptId: "a1", turn: 1, step: 1, revision: 2, index: 0, chunk: { type: "reasoning-delta", index: 0, text: "先想想" } } };
    yield { type: "assistant-stream", frame: { type: "chunk", attemptId: "a1", turn: 1, step: 1, revision: 2, index: 0, chunk: { type: "text-delta", index: 0, text: "流式" } } };
    yield { type: "event", event: { type: "tool/call", seq: 91, data: { turn: 1, step: 1, callId: "c1", name: "run_code", arguments: "{\"code\":\"console.log(1)\",\"description\":\"读 handoff 文档\"}" } } };
    yield { type: "event", event: { type: "tool/result", seq: 92, data: { turn: 1, step: 1, message: { role: "tool", toolCallId: "c1", content: [{ type: "text", text: "exit 0" }], isError: false } } } };
    yield { type: "assistant-stream", frame: { type: "end", attemptId: "a1", outcome: { kind: "committed" } } };
    // Committed messages carry reasoning even when no reasoning frame streams.
    yield { type: "event", event: { type: "assistant/message", seq: 93, data: { turn: 1, step: 1, message: { id: "m1", content: [{ type: "reasoning", text: "已提交的思考" }, { type: "text", text: "流式" }] } } } };
    yield { type: "event", event: { type: "turn/end", seq: 94, data: { turn: 1, reason: { kind: "completed" } } } };
  },
};

// Workspace membership is what DSH groups by. session-orphan sits in /tmp/other
// but is not attached there, which is exactly the ungrouped state a cwd-only
// create leaves behind.
const attachedCalls = [];
const detachedCalls = [];
const workspaces = [
  {
    id: "ws-1",
    path: "/tmp/project",
    sessionIds: ["session-abc"],
    async attachSession(id) {
      attachedCalls.push({ workspaceId: "ws-1", id });
      if (!this.sessionIds.includes(id)) this.sessionIds.push(id);
    },
    async detachSession(id) {
      detachedCalls.push({ workspaceId: "ws-1", id });
      this.sessionIds = this.sessionIds.filter((existing) => existing !== id);
    },
  },
  {
    id: "ws-2",
    path: "/tmp/other",
    sessionIds: [],
    async attachSession(id) {
      attachedCalls.push({ workspaceId: "ws-2", id });
      if (!this.sessionIds.includes(id)) this.sessionIds.push(id);
    },
    async detachSession(id) {
      detachedCalls.push({ workspaceId: "ws-2", id });
      this.sessionIds = this.sessionIds.filter((existing) => existing !== id);
    },
  },
];
const registry = {
  archivedSessionIds: [],
  list() {
    return workspaces;
  },
  get(id) {
    return workspaces.find((workspace) => workspace.id === id);
  },
};

const bridge = new WidgetBridge({
  controller,
  registry,
  port: 0,
  discoveryPath,
  token,
  devicesPath: join(dir, "devices.json"),
  auditPath: join(dir, "audit.log"),
});
await bridge.start();
try {
  const discovery = JSON.parse(readFileSync(discoveryPath, "utf8"));
  assert.equal(discovery.token, token);
  assert.ok(discovery.port > 0);

  const health = await fetch("http://127.0.0.1:" + discovery.port + "/v1/health");
  assert.equal(health.status, 200);
  const healthBody = await health.json();
  assert.equal(healthBody.version, 2);
  assert.equal(healthBody.capabilities.pairing, true);
  assert.equal(healthBody.capabilities.push, false);

  const unauthorized = await fetch("http://127.0.0.1:" + discovery.port + "/v1/sessions");
  assert.equal(unauthorized.status, 401);

  const headers = { authorization: "Bearer " + token };
  const list = await fetch("http://127.0.0.1:" + discovery.port + "/v1/sessions", { headers });
  assert.equal(list.status, 200);
  const listed = await list.json();
  assert.equal(listed.sessions[0].id, "session-abc");

  // A cwd-only create leaves a session ungrouped. Startup reconciliation must
  // attach every such session to the Workspace that owns its cwd.
  const reconciled = await bridge.attachOrphanSessions();
  assert.deepEqual(reconciled.attached, [{ sessionId: "session-orphan", workspaceId: "ws-2" }]);
  assert.deepEqual(attachedCalls, [{ workspaceId: "ws-2", id: "session-orphan" }]);

  const postJson = (path, body, method = "POST") =>
    fetch("http://127.0.0.1:" + discovery.port + path, {
      method,
      headers: { ...headers, "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });

  // Creating from the widget under a Workspace directory must join that
  // Workspace, otherwise DSH renders it under "未分组".
  const created = await postJson("/v1/sessions", { cwd: "/tmp/project" });
  assert.equal(created.status, 200);
  assert.deepEqual(lastCreateRequest, { workspaceId: "ws-1" });
  assert.equal((await created.json()).workspaceId, "ws-1");

  // A directory that is not a Workspace keeps the plain cwd behaviour.
  const untracked = await postJson("/v1/sessions", { cwd: "/tmp/elsewhere" });
  assert.equal(untracked.status, 200);
  assert.deepEqual(lastCreateRequest, { cwd: "/tmp/elsewhere" });
  assert.equal((await untracked.json()).workspaceId, null);

  // Explicit membership changes for sessions that already exist.
  const attached = await postJson("/v1/sessions/session-orphan/workspace", { workspaceId: "ws-1" });
  assert.equal(attached.status, 200);
  assert.deepEqual(await attached.json(), { sessionId: "session-orphan", workspaceId: "ws-1", attached: true });
  assert.deepEqual(attachedCalls.at(-1), { workspaceId: "ws-1", id: "session-orphan" });

  const detached = await postJson("/v1/sessions/session-orphan/workspace", undefined, "DELETE");
  assert.equal(detached.status, 200);
  assert.deepEqual(await detached.json(), { sessionId: "session-orphan", workspaceId: "ws-1", attached: false });
  assert.deepEqual(detachedCalls.at(-1), { workspaceId: "ws-1", id: "session-orphan" });

  const missingWorkspace = await postJson("/v1/sessions", { workspaceId: "ws-nope" });
  assert.equal(missingWorkspace.status, 404);

  const history = await fetch("http://127.0.0.1:" + discovery.port + "/v1/sessions/session-abc/history", { headers });
  const historyBody = await history.json();
  assert.equal(historyBody.messages.length, 2);

  const smallHistory = await fetch(
    "http://127.0.0.1:" + discovery.port + "/v1/sessions/session-old/history?limit=3",
    { headers }
  );
  assert.equal(smallHistory.status, 200);
  const smallBody = await smallHistory.json();
  assert.ok(Array.isArray(smallBody.messages));

  const allHistory = await fetch(
    "http://127.0.0.1:" + discovery.port + "/v1/sessions/session-old/history?all=1",
    { headers }
  );
  assert.equal(allHistory.status, 200);
  const allBody = await allHistory.json();
  assert.equal(allBody.messages.length, 3);
  assert.equal(allBody.hasMore, false);

  const emptyHistory = await fetch(
    "http://127.0.0.1:" + discovery.port + "/v1/sessions/session-empty/history?all=1",
    { headers }
  );
  assert.equal(emptyHistory.status, 200);
  const emptyBody = await emptyHistory.json();
  assert.equal(emptyBody.messages.length, 0);
  assert.equal(emptyBody.hasMore, false);

  const afterHistory = await fetch(
    "http://127.0.0.1:" + discovery.port + "/v1/sessions/session-old/history?after=1",
    { headers }
  );
  assert.equal(afterHistory.status, 200);
  const afterBody = await afterHistory.json();
  assert.equal(afterBody.messages.length, 1);
  assert.equal(afterBody.messages[0].seq, 2);

  // Scrollback paging: before=<seq> must return the page older than that seq,
  // not the tail snapshot again.
  const beforeHistory = await fetch(
    "http://127.0.0.1:" + discovery.port + "/v1/sessions/session-old/history?before=1",
    { headers }
  );
  assert.equal(beforeHistory.status, 200);
  const beforeBody = await beforeHistory.json();
  assert.equal(beforeBody.messages.length, 1);
  assert.equal(beforeBody.messages[0].seq, 0);
  assert.equal(beforeBody.hasMore, false);

  const beforeWide = await fetch(
    "http://127.0.0.1:" + discovery.port + "/v1/sessions/session-old/history?before=999&limit=3",
    { headers }
  );
  assert.equal(beforeWide.status, 200);
  const beforeWideBody = await beforeWide.json();
  assert.equal(beforeWideBody.messages.length, 3);
  assert.equal(beforeWideBody.messages[2].seq, 2);

  const badBefore = await fetch(
    "http://127.0.0.1:" + discovery.port + "/v1/sessions/session-old/history?before=abc",
    { headers }
  );
  assert.equal(badBefore.status, 400);

  const prompt = await fetch("http://127.0.0.1:" + discovery.port + "/v1/sessions/session-abc/prompt", {
    method: "POST",
    headers: { ...headers, "content-type": "application/json" },
    body: JSON.stringify({ text: "测试" }),
  });
  assert.equal(prompt.status, 200);
  assert.deepEqual(lastPromptContent, [{ type: "text", text: "测试" }]);

  // A pasted image travels as canonical base64 and must reach the controller
  // as an encoded image part. DSH admits (stores + hashes) it itself; the
  // bridge must never pre-resolve it into a durable reference.
  const imagePrompt = await postJson("/v1/sessions/session-abc/prompt", {
    text: "测试",
    images: [{ data: "aGVsbG8=", mediaType: "image/png", name: "shot.png" }],
  });
  assert.equal(imagePrompt.status, 200);
  assert.equal(lastPromptContent.length, 2);
  assert.deepEqual(lastPromptContent[1], {
    type: "image",
    data: "aGVsbG8=",
    mediaType: "image/png",
    name: "shot.png",
  });

  const emptyPrompt = await postJson("/v1/sessions/session-abc/prompt", { text: "  " });
  assert.equal(emptyPrompt.status, 400);

  // Device pairing: the host token opens a 6-digit window, the code mints a
  // device token, and that token is revocable on its own.
  const pairNoToken = await fetch("http://127.0.0.1:" + discovery.port + "/v1/pair/start", { method: "POST" });
  assert.equal(pairNoToken.status, 401);

  const pairStart = await postJson("/v1/pair/start", { label: "iPhone" });
  assert.equal(pairStart.status, 200);
  const ticket = await pairStart.json();
  assert.match(ticket.code, /^[0-9]{6}$/u);
  assert.ok(Date.parse(ticket.expiresAt) > Date.now());
  // The QR payload has to be self-contained: the phone gets scheme, base URL
  // and code from one scan, plus the other reachable base URLs for later.
  assert.match(ticket.uri, /^dshwidget:\/\/pair\?/u);
  const qr = new URLSearchParams(ticket.uri.slice("dshwidget://pair?".length));
  assert.equal(qr.get("v"), "1");
  assert.ok((qr.get("u") ?? "").startsWith("http"));
  assert.equal(qr.get("c"), ticket.code);
  assert.ok(Array.isArray(ticket.addrs) && ticket.addrs.length >= 1);
  assert.equal(ticket.addrs[0], qr.get("u"));
  assert.ok(ticket.addrs.every((u) => u.startsWith("http")));
  if (ticket.addrs.length > 1) assert.equal(qr.get("a"), ticket.addrs.join(","));

  const wrongCode = ticket.code === "000000" ? "111111" : "000000";
  const claimWrong = await postJson("/v1/pair/claim", { code: wrongCode, name: "iPhone" });
  assert.equal(claimWrong.status, 401);

  const claim = await postJson("/v1/pair/claim", { code: ticket.code, name: "iPhone 15" });
  assert.equal(claim.status, 200);
  const claimed = await claim.json();
  assert.equal(claimed.device.name, "iPhone 15");
  assert.match(claimed.deviceToken, /^[0-9a-f]{64}$/u);
  const deviceHeaders = { authorization: "Bearer " + claimed.deviceToken };

  const deviceList = await fetch("http://127.0.0.1:" + discovery.port + "/v1/sessions", { headers: deviceHeaders });
  assert.equal(deviceList.status, 200);

  // A paired device can read sessions but cannot mint other devices.
  const devicePairStart = await fetch("http://127.0.0.1:" + discovery.port + "/v1/pair/start", {
    method: "POST",
    headers: { ...deviceHeaders, "content-type": "application/json" },
    body: JSON.stringify({ label: "iPad" }),
  });
  assert.equal(devicePairStart.status, 403);

  // A pairing code is single use.
  const claimAgain = await postJson("/v1/pair/claim", { code: ticket.code, name: "second" });
  assert.equal(claimAgain.status, 400);

  const devices = await fetch("http://127.0.0.1:" + discovery.port + "/v1/devices", { headers });
  assert.equal(devices.status, 200);
  const deviceBody = await devices.json();
  assert.equal(deviceBody.devices.length, 1);
  assert.equal(deviceBody.devices[0].name, "iPhone 15");
  assert.equal(deviceBody.devices[0].tokenHash, undefined);

  const revoked = await fetch(
    "http://127.0.0.1:" + discovery.port + "/v1/devices/" + encodeURIComponent(deviceBody.devices[0].id),
    { method: "DELETE", headers },
  );
  assert.equal(revoked.status, 200);
  const afterRevoke = await fetch("http://127.0.0.1:" + discovery.port + "/v1/sessions", { headers: deviceHeaders });
  assert.equal(afterRevoke.status, 401);

  const push = await postJson("/v1/push/register", { token: "x" });
  assert.equal(push.status, 501);

  const abort = new AbortController();
  const stream = await fetch("http://127.0.0.1:" + discovery.port + "/v1/sessions/session-abc/events", { headers, signal: abort.signal });
  const reader = stream.body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline && !text.includes("event: turn_end")) {
    const { value, done } = await reader.read();
    if (done) break;
    text += decoder.decode(value, { stream: true });
  }
  abort.abort();
  assert.match(text, /event: snapshot/);
  assert.match(text, /event: assistant_delta/);
  assert.match(text, /event: reasoning_delta/);
  assert.match(text, /event: reasoning_block/);
  assert.match(text, /"text":"已提交的思考"/);
  assert.match(text, /"text":"先想想"/);
  assert.match(text, /event: tool_call/);
  assert.match(text, /"name":"run_code"/);
  assert.match(text, /"detail":"读 handoff 文档"/);
  assert.match(text, /event: tool_result/);
  assert.match(text, /"ok":true/);
  assert.match(text, /event: assistant_end/);
  assert.match(text, /event: turn_end/);
  assert.match(text, /"reason":"completed"/);
  console.log("bridge http test passed");
} finally {
  await bridge.stop();
  rmSync(dir, { recursive: true, force: true });
}

const applyDir = mkdtempSync(join(tmpdir(), "dsh-widget-apply-"));
const applyDiscovery = join(applyDir, "bridge.json");
const fakeCtx = {
  get(service) {
    if (service === "sessionController") return controller;
    if (service === "workspaceRegistry") return registry;
    throw new Error("unknown service " + service);
  },
};
// Leave session-orphan unowned so apply() has something to reconcile.
await workspaces[1].detachSession("session-orphan");
const beforeApply = attachedCalls.length;
const dispose = apply(fakeCtx, { discoveryPath: applyDiscovery, port: 0 });
try {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline && !existsSync(applyDiscovery)) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.ok(existsSync(applyDiscovery), "plugin apply must publish discovery");
  const info = JSON.parse(readFileSync(applyDiscovery, "utf8"));
  assert.ok(info.port > 0);
  const response = await fetch("http://127.0.0.1:" + info.port + "/v1/health");
  assert.equal(response.status, 200);

  // apply() must reconcile orphans once the registry is visible, not only when
  // the class is driven directly.
  const attachDeadline = Date.now() + 3000;
  while (Date.now() < attachDeadline && attachedCalls.length === beforeApply) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(attachedCalls.length, beforeApply + 1);
  assert.deepEqual(attachedCalls.at(-1), { workspaceId: "ws-2", id: "session-orphan" });
  console.log("bridge apply test passed");
} finally {
  dispose();
  await new Promise((resolve) => setTimeout(resolve, 300));
  rmSync(applyDir, { recursive: true, force: true });
}

// A bridge reachable from the public internet must throttle one client before
// the work reaches the session controller.
const limitDir = mkdtempSync(join(tmpdir(), "dsh-widget-limit-"));
const limitDiscovery = join(limitDir, "bridge.json");
const limitBridge = new WidgetBridge({
  controller,
  registry,
  port: 0,
  token,
  discoveryPath: limitDiscovery,
  devicesPath: join(limitDir, "devices.json"),
  auditPath: join(limitDir, "audit.log"),
  requestsPerMinute: 3,
});
await limitBridge.start();
try {
  const info = JSON.parse(readFileSync(limitDiscovery, "utf8"));
  const statuses = [];
  for (let i = 0; i < 5; i += 1) {
    const response = await fetch("http://127.0.0.1:" + info.port + "/v1/health");
    statuses.push(response.status);
  }
  assert.deepEqual(statuses, [200, 200, 200, 429, 429]);
  console.log("bridge rate limit test passed");
} finally {
  await limitBridge.stop();
  rmSync(limitDir, { recursive: true, force: true });
}