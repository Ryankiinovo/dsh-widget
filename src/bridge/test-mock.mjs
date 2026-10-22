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
    assert.equal(request.content[0].text, "测试");
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
    if (request.address.sessionId === "session-empty") {
      // A brand-new session can finish its follow iterator without any
      // snapshot. The bridge must read that as empty history, not a 500.
      return;
    }
    if (request.address.sessionId === "session-old") {
      yield { type: "snapshot", records: events, hasMore: true, cursor: 2 };
      return;
    }
    assert.equal(request.address.sessionId, "session-abc");
    assert.deepEqual(request.turnWindow, { minMessages: 20, minTurns: 2 });
    yield { type: "snapshot", records: events, hasMore: false, cursor: 2 };
    yield { type: "assistant-stream", frame: { type: "start", attemptId: "a1", turn: 1, step: 1, revision: 1 } };
    yield { type: "assistant-stream", frame: { type: "chunk", attemptId: "a1", turn: 1, step: 1, revision: 2, index: 0, chunk: { type: "text-delta", index: 0, text: "流式" } } };
    yield { type: "assistant-stream", frame: { type: "end", attemptId: "a1", outcome: { kind: "committed" } } };
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

const bridge = new WidgetBridge({ controller, registry, port: 0, discoveryPath, token });
await bridge.start();
try {
  const discovery = JSON.parse(readFileSync(discoveryPath, "utf8"));
  assert.equal(discovery.token, token);
  assert.ok(discovery.port > 0);

  const health = await fetch("http://127.0.0.1:" + discovery.port + "/v1/health");
  assert.equal(health.status, 200);

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

  const prompt = await fetch("http://127.0.0.1:" + discovery.port + "/v1/sessions/session-abc/prompt", {
    method: "POST",
    headers: { ...headers, "content-type": "application/json" },
    body: JSON.stringify({ text: "测试" }),
  });
  assert.equal(prompt.status, 200);

  const abort = new AbortController();
  const stream = await fetch("http://127.0.0.1:" + discovery.port + "/v1/sessions/session-abc/events", { headers, signal: abort.signal });
  const reader = stream.body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline && !text.includes("event: assistant_end")) {
    const { value, done } = await reader.read();
    if (done) break;
    text += decoder.decode(value, { stream: true });
  }
  abort.abort();
  assert.match(text, /event: snapshot/);
  assert.match(text, /event: assistant_delta/);
  assert.match(text, /event: assistant_end/);
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