/**
 * Security primitives for the DSH widget bridge.
 *
 * The bridge is a loopback service by default, guarded by one random
 * per-process token. Once it is reachable from another machine (Tailscale
 * Funnel, a reverse proxy, a port forward) that single token stops being an
 * acceptable boundary: it is copied into every client, cannot be revoked for
 * one device only, and nothing limits guessing or abuse.
 *
 * This module adds the pieces the protocol contract promises:
 * - per-device tokens that can be revoked independently
 * - short-lived pairing codes (6 digits, 120 s, single use)
 * - sliding-window rate limiting and failure lockout
 * - an append-only audit log
 */
import { createHash, randomBytes, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import {
  appendFileSync,
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";

export const PAIRING_CODE_LENGTH = 6;
export const PAIRING_TTL_MS = 120_000;
export const PAIRING_MAX_ATTEMPTS = 10;
export const DEVICE_TOKEN_BYTES = 32;
export const DEFAULT_AUDIT_MAX_BYTES = 2 * 1024 * 1024;

export function sha256Hex(value) {
  return createHash("sha256").update(String(value)).digest("hex");
}

/** Constant-time compare that never throws on length mismatch. */
export function safeEqual(a, b) {
  const left = Buffer.from(String(a ?? ""));
  const right = Buffer.from(String(b ?? ""));
  if (left.length === 0 || left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

export function isoAt(ms) {
  return new Date(ms).toISOString();
}

/** Sliding-window counter: hit() returns whether the call is allowed. */
export class RateLimiter {
  constructor({ windowMs = 60_000, max = 120, now = Date.now } = {}) {
    this.windowMs = windowMs;
    this.max = max;
    this.now = now;
    this.hits = new Map();
  }

  hit(key) {
    const at = this.now();
    const entry = this.hits.get(key);
    if (!entry || at - entry.start >= this.windowMs) {
      this.hits.set(key, { start: at, count: 1 });
      this.sweep(at);
      return { allowed: true, remaining: this.max - 1, retryAfterMs: 0 };
    }
    entry.count += 1;
    if (entry.count > this.max) {
      return { allowed: false, remaining: 0, retryAfterMs: this.windowMs - (at - entry.start) };
    }
    return { allowed: true, remaining: this.max - entry.count, retryAfterMs: 0 };
  }

  reset(key) {
    this.hits.delete(key);
  }

  sweep(at = this.now()) {
    if (this.hits.size < 512) return;
    for (const [key, entry] of this.hits) {
      if (at - entry.start >= this.windowMs) this.hits.delete(key);
    }
  }
}

/**
 * One active pairing window at a time. A code is single use, expires after
 * ttlMs, and dies after maxAttempts wrong guesses so a 6-digit space cannot be
 * walked in the 120 s window.
 */
export class PairingStore {
  constructor({ ttlMs = PAIRING_TTL_MS, maxAttempts = PAIRING_MAX_ATTEMPTS, codeLength = PAIRING_CODE_LENGTH, now = Date.now } = {}) {
    this.ttlMs = ttlMs;
    this.maxAttempts = maxAttempts;
    this.codeLength = codeLength;
    this.now = now;
    this.current = null;
  }

  start() {
    const ceiling = 10 ** this.codeLength;
    const code = String(randomInt(0, ceiling)).padStart(this.codeLength, "0");
    const expiresAt = this.now() + this.ttlMs;
    this.current = { code, expiresAt, attempts: 0 };
    return { code, expiresAt: isoAt(expiresAt), ttlMs: this.ttlMs };
  }

  /** Consume the code. Returns {ok:true} at most once per started session. */
  claim(code) {
    const current = this.current;
    if (!current) return { ok: false, error: "pairing/not-started" };
    if (this.now() >= current.expiresAt) {
      this.current = null;
      return { ok: false, error: "pairing/expired" };
    }
    current.attempts += 1;
    if (current.attempts > this.maxAttempts) {
      this.current = null;
      return { ok: false, error: "pairing/too-many-attempts" };
    }
    if (!safeEqual(String(code ?? ""), current.code)) {
      return { ok: false, error: "pairing/invalid-code" };
    }
    this.current = null;
    return { ok: true };
  }

  cancel() {
    this.current = null;
  }

  get active() {
    return Boolean(this.current && this.now() < this.current.expiresAt);
  }
}

function cleanName(value, fallback = "未命名设备") {
  const text = typeof value === "string" ? value.replace(/[\u0000-\u001f\u007f]/gu, " ").trim() : "";
  if (!text) return fallback;
  return text.slice(0, 60);
}

function publicDevice(device) {
  return {
    id: device.id,
    name: device.name,
    createdAt: device.createdAt,
    lastSeenAt: device.lastSeenAt,
    lastIp: device.lastIp,
  };
}

/**
 * Device registry persisted as a 0600 JSON file. Only token hashes are stored;
 * the plaintext token exists exactly once, in the claim response.
 */
export class DeviceStore {
  constructor({ path, now = Date.now } = {}) {
    this.path = path ?? null;
    this.now = now;
    this.devices = [];
    this.load();
  }

  load() {
    if (!this.path) return;
    try {
      const raw = JSON.parse(readFileSync(this.path, "utf8"));
      if (Array.isArray(raw?.devices)) {
        this.devices = raw.devices.filter((device) => typeof device?.tokenHash === "string" && typeof device?.id === "string");
      }
    } catch {
      this.devices = [];
    }
  }

  save() {
    if (!this.path) return;
    mkdirSync(dirname(this.path), { recursive: true });
    const temporary = this.path + "." + String(process.pid) + ".tmp";
    writeFileSync(temporary, JSON.stringify({ version: 1, devices: this.devices }, null, 2), { mode: 0o600 });
    chmodSync(temporary, 0o600);
    renameSync(temporary, this.path);
    chmodSync(this.path, 0o600);
  }

  addDevice({ name, ip } = {}) {
    const token = randomBytes(DEVICE_TOKEN_BYTES).toString("hex");
    const at = isoAt(this.now());
    const device = {
      id: randomUUID(),
      name: cleanName(name),
      tokenHash: sha256Hex(token),
      createdAt: at,
      lastSeenAt: at,
      lastIp: typeof ip === "string" ? ip : null,
    };
    this.devices.push(device);
    this.save();
    return { token, device: publicDevice(device) };
  }

  verify(token) {
    const hash = sha256Hex(String(token ?? ""));
    const device = this.devices.find((candidate) => safeEqual(candidate.tokenHash, hash));
    if (!device) return null;
    device.lastSeenAt = isoAt(this.now());
    return publicDevice(device);
  }

  revoke(id) {
    const before = this.devices.length;
    this.devices = this.devices.filter((device) => device.id !== String(id));
    const removed = this.devices.length !== before;
    if (removed) this.save();
    return removed;
  }

  list() {
    return this.devices.map(publicDevice);
  }
}

/** Append-only JSONL audit log with a single size-based rotation. */
export class AuditLog {
  constructor({ path, maxBytes = DEFAULT_AUDIT_MAX_BYTES, now = Date.now } = {}) {
    this.path = path ?? null;
    this.maxBytes = maxBytes;
    this.now = now;
  }

  record(entry) {
    if (!this.path) return;
    const line = JSON.stringify({ at: isoAt(this.now()), ...entry }) + "\n";
    try {
      mkdirSync(dirname(this.path), { recursive: true });
      appendFileSync(this.path, line, { mode: 0o600 });
      this.rotateIfNeeded();
    } catch {
      // Auditing must never break a request.
    }
  }

  rotateIfNeeded() {
    try {
      if (statSync(this.path).size <= this.maxBytes) return;
      renameSync(this.path, this.path + ".1");
    } catch {}
  }
}
