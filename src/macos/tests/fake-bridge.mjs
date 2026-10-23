#!/usr/bin/env node
// Fault-injection bridge for the reconnect test. It mimics the subset of the
// widget bridge API that the app talks to, then kills the first event stream in
// the middle of a reply — exactly the failure that used to swallow the answer.
import http from "node:http";
import { writeFileSync } from "node:fs";

const TOKEN = "test-token";
const portFile = process.argv[2];
// "cut" kills the socket mid-reply; "stall" keeps it open but sends nothing, so
// only the client-side stall watchdog can notice the dead stream.
const MODE = process.env.FAKE_BRIDGE_MODE || "cut";
const SESSION_ID = "sess-test";
const USER = { id: "u1", role: "user", text: "run the test", seq: 1 };
const FINAL = [
  USER,
  { id: "a1", role: "assistant", text: "final answer", seq: 2, turn: 1, step: 1 },
];

const state = {
  streamConnections: 0,
  running: true,
  messages: [USER],
};

function json(res, code, body) {
  const data = JSON.stringify(body);
  res.writeHead(code, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(data),
  });
  res.end(data);
}

function sse(res, event, payload) {
  res.write("event: " + event + "\ndata: " + JSON.stringify(payload) + "\n\n");
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.headers.authorization !== "Bearer " + TOKEN) {
    return json(res, 401, { error: { code: "unauthorized", message: "bad token" } });
  }
  if (url.pathname === "/v1/sessions" && req.method === "GET") {
    return json(res, 200, {
      sessions: [{
        id: SESSION_ID,
        title: "fixture",
        cwd: "/tmp/fixture",
        updatedAt: Date.now(),
        running: state.running,
        blank: false,
        agentAvailable: true,
      }],
    });
  }
  if (url.pathname === "/v1/sessions/" + SESSION_ID + "/history") {
    const after = url.searchParams.get("after");
    const all = url.searchParams.get("all") === "1";
    const messages = (all || !after)
      ? state.messages
      : state.messages.filter((message) => (message.seq ?? 0) > Number(after));
    return json(res, 200, {
      messages,
      hasMore: false,
      oldestSeq: state.messages[0]?.seq ?? null,
      newestSeq: state.messages.at(-1)?.seq ?? null,
    });
  }
  if (url.pathname === "/v1/sessions/" + SESSION_ID + "/events") {
    return streamEvents(req, res);
  }
  json(res, 404, { error: { code: "not-found", message: url.pathname } });
});

function streamEvents(req, res) {
  state.streamConnections += 1;
  const attempt = state.streamConnections;
  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
  });
  res.write(": connected\n\n");
  sse(res, "snapshot", { messages: state.messages, hasMore: false });
  const ping = setInterval(() => res.write(": ping\n\n"), 15000);
  const cleanup = () => clearInterval(ping);
  res.on("close", cleanup);
  req.on("close", cleanup);

  if (attempt === 1) {
    sse(res, "assistant_start", { turn: 1, step: 1 });
    sse(res, "assistant_delta", { text: "partial ", turn: 1, step: 1 });
    setTimeout(() => {
      sse(res, "assistant_delta", { text: "answer", turn: 1, step: 1 });
      // The run finishes inside the reconnect gap: /history gets the final
      // reply while the stream dies before assistant_end is delivered.
      state.messages = FINAL;
      state.running = false;
      if (MODE === "stall") {
        clearInterval(ping);
        return;
      }
      setTimeout(() => res.destroy(), 150);
    }, 500);
  }
}

server.listen(0, "127.0.0.1", () => {
  const { port } = server.address();
  if (portFile) writeFileSync(portFile, String(port));
  console.log("fake bridge on " + port);
});

process.on("SIGTERM", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));
