#!/usr/bin/env node
// Dev server for the obs_factor frontend. Test tooling, not the product.
//
// Serves priv/static the way the Phoenix app will (docs/contract.md, Auth),
// and answers /api/snapshot, /api/stream and /api/history from the fixtures
// in test/fixtures/frontend/. No dependencies.
//
//   node scripts/dev-static.mjs [--port 4010] [--fixture box|bad-day]
//                               [--tick 5000] [--password dev] [--no-auth]
//
// Dev-only controls (never in the shipped page):
//   GET /__dev/fixture?name=bad-day   switch fixture for every client
//   GET /__dev/pause                  stop sending snapshots (clock goes stale)
//   GET /__dev/resume
//   GET /__dev/drop                   close every open stream (reconnect path)
//   GET /__dev/expire                 forget every session and drop streams (401 path)
//
// The stream re-sends the fixture every tick with `at` set to now. Known
// numbers wobble by a few percent so motion is visible; nulls stay null.
// History is synthesised from the fixture's current values (seeded, so the
// same request gives the same curve), with nulls where the source is failing.

import { createServer } from "node:http";
import { readFileSync, statSync, existsSync } from "node:fs";
import { extname, join, normalize, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const STATIC = join(root, "priv/static");
const FIXTURES = join(root, "test/fixtures/frontend");

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : dflt;
};
const PORT = Number(opt("port", 4010));
let fixtureName = opt("fixture", "box");
const TICK = Number(opt("tick", 0)) || null;
const PASSWORD = opt("password", "dev");
const AUTH = !args.includes("--no-auth");

const sessions = new Set();
const streams = new Set();
let paused = false;

const loadFixture = (name) => {
  const file = join(FIXTURES, `${name}.json`);
  if (!existsSync(file)) throw new Error(`no fixture ${file}`);
  return JSON.parse(readFileSync(file, "utf8"));
};
let fixture = loadFixture(fixtureName);

const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".json": "application/json", ".svg": "image/svg+xml", ".ico": "image/x-icon",
  ".png": "image/png", ".txt": "text/plain; charset=utf-8", ".woff2": "font/woff2",
};

function cookieSession(req) {
  const m = /(?:^|;\s*)obs_dev=([a-f0-9]+)/.exec(req.headers.cookie ?? "");
  return m && sessions.has(m[1]);
}

function wobble(snap, seq) {
  const s = structuredClone(snap);
  s.at = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  const f = (x, k) => (typeof x === "number" ? Math.max(0, x * (1 + 0.08 * Math.sin(seq * 1.7 + k))) : x);
  let k = 0;
  for (const e of s.edges) {
    if (!(e.rate != null && e.rate > 0)) continue;
    const w = f(1, k++);
    e.rate = round(e.rate * w);
    if (e.codes) for (const c of Object.keys(e.codes)) e.codes[c] = round(e.codes[c] * w);
  }
  for (const n of s.nodes) {
    if (n.container) {
      n.container.cpu_cores = n.container.cpu_cores == null ? null : round(f(n.container.cpu_cores, k++), 5);
      if (n.container.uptime_s != null) n.container.uptime_s += Math.round((Date.now() - Date.parse(snap.at)) / 1000);
    }
    if (n.headline?.unit === "req/s" && n.headline.value) n.headline.value = round(f(n.headline.value, k++));
    for (const h of n.hosts) {
      if (!h.rps) continue;
      const w = f(1, k++);
      h.rps = round(h.rps * w);
      if (h.codes) for (const c of Object.keys(h.codes)) h.codes[c] = round(h.codes[c] * w);
      if (h.out_bps != null) h.out_bps = round(h.out_bps * w, 1);
    }
  }
  if (s.host.cpu_used_cores != null) s.host.cpu_used_cores = round(f(s.host.cpu_used_cores, 99), 3);
  for (const n of s.nodes) if (n.id === "host-cpu") n.headline.value = s.host.cpu_used_cores;
  return s;
}
const round = (x, d = 3) => Math.round(x * 10 ** d) / 10 ** d;

// mulberry32
function rng(seed) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const hash = (str) => [...str].reduce((h, c) => (Math.imul(h, 31) + c.charCodeAt(0)) | 0, 7);

function history(node, res) {
  const step = res === "5s" ? 5000 : 60000;
  const count = res === "5s" ? 720 : 1440;
  const now = Math.floor(Date.now() / step) * step;
  const series = [];
  const add = (key, label, unit, value, opts = {}) => {
    const r = rng(hash(node.id + key + res));
    const points = [];
    let walk = 0;
    for (let i = 0; i < count; i++) {
      const t = now - (count - 1 - i) * step;
      walk = walk * 0.92 + (r() - 0.5) * 0.25;
      const daily = res === "1m" ? 0.35 * Math.sin((i / count) * Math.PI * 2 - 1.2) : 0;
      let v = value == null ? null : Math.max(0, value * (1 + walk + daily));
      if (opts.ramp && v != null) v = value * (0.55 + 0.45 * (i / count) ** 3);
      if (opts.nullTail && i > count - opts.nullTail) v = null;
      if (opts.gapAt && i > opts.gapAt[0] && i < opts.gapAt[1]) v = null;
      points.push([t, v == null ? null : round(v, 4)]);
    }
    series.push({ key, label, unit, points });
  };
  const bad = fixtureName === "bad-day";
  const c = node.container;
  if (c) {
    add("cpu_cores", "CPU", "cores", c.cpu_cores ?? (bad ? 0.02 : null), { nullTail: c.cpu_cores == null ? 60 : 0 });
    add("mem_bytes", "Memory", "bytes", c.mem_bytes ?? 170e6, { ramp: node.status === "blocked" && node.id !== "db", nullTail: c.mem_bytes == null ? 60 : 0 });
    add("net_rx_bps", "Net in", "B/s", c.net_rx_bps ?? 4000, { nullTail: c.net_rx_bps == null ? 60 : 0 });
  }
  if (node.hosts.length || node.id === "caddy" || node.id === "internet") {
    const rps = node.headline?.unit === "req/s" ? node.headline.value : null;
    add("rps", "Requests", "req/s", rps ?? 1.2, { nullTail: rps == null ? (res === "5s" ? 140 : 12) : 0 });
    add("err_rps", "Errors", "req/s", rps == null ? 0.02 : 0.01 + rps * 0.004, { nullTail: rps == null ? (res === "5s" ? 140 : 12) : 0 });
  }
  if (node.kind === "db") add("connections", "Connections", "conns", node.headline.value, { ramp: bad });
  if (node.id === "host-cpu") add("cpu_used_cores", "CPU used", "cores", node.headline.value);
  if (node.id === "host-mem") add("mem_used_bytes", "Memory used", "bytes", fixture.host.mem_used_bytes);
  if (node.id === "host-disk") add("disk_used_bytes", "Disk used", "bytes", fixture.host.disk_used_bytes, { ramp: false });
  return { node: node.id, res, series };
}

function sendJSON(res, code, body) {
  res.writeHead(code, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

function serveFile(res, file) {
  try {
    const st = statSync(file);
    if (!st.isFile()) throw new Error("not a file");
    res.writeHead(200, { "content-type": MIME[extname(file)] ?? "application/octet-stream", "cache-control": "no-store" });
    res.end(readFileSync(file));
  } catch {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  }
}

let seq = 0;
function broadcast() {
  if (paused) return;
  const snap = wobble(fixture, ++seq);
  const msg = `event: snapshot\ndata: ${JSON.stringify(snap)}\n\n`;
  for (const s of streams) s.write(msg);
}
setInterval(broadcast, TICK ?? fixture.tick_ms ?? 5000);

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;
  const authed = !AUTH || cookieSession(req);

  if (p.startsWith("/__dev/")) {
    if (p === "/__dev/fixture") {
      fixtureName = url.searchParams.get("name") ?? "box";
      fixture = loadFixture(fixtureName);
      broadcast();
    } else if (p === "/__dev/pause") paused = true;
    else if (p === "/__dev/resume") { paused = false; broadcast(); }
    else if (p === "/__dev/drop") { for (const s of streams) s.end(); streams.clear(); }
    else if (p === "/__dev/expire") { sessions.clear(); for (const s of streams) s.end(); streams.clear(); }
    return sendJSON(res, 200, { fixture: fixtureName, paused, streams: streams.size });
  }

  if (p === "/health") { res.writeHead(200); return res.end("ok"); }

  if (p === "/login" && req.method === "GET") return serveFile(res, join(STATIC, "login.html"));
  if (p === "/login" && req.method === "POST") {
    let body = "";
    for await (const chunk of req) body += chunk;
    const pw = new URLSearchParams(body).get("password");
    if (pw === PASSWORD) {
      const id = randomBytes(16).toString("hex");
      sessions.add(id);
      res.writeHead(303, { location: "/", "set-cookie": `obs_dev=${id}; Path=/; HttpOnly; SameSite=Lax` });
    } else {
      res.writeHead(303, { location: "/login?error=1" });
    }
    return res.end();
  }
  if (p === "/logout" && req.method === "POST") {
    res.writeHead(303, { location: "/login", "set-cookie": "obs_dev=; Path=/; Max-Age=0" });
    return res.end();
  }

  if (p.startsWith("/api/")) {
    if (!authed) return sendJSON(res, 401, { error: "unauthorized" });
    if (p === "/api/snapshot") return sendJSON(res, 200, wobble(fixture, seq));
    if (p === "/api/history") {
      const node = fixture.nodes.find((n) => n.id === url.searchParams.get("node"));
      const r = url.searchParams.get("res");
      if (!node) return sendJSON(res, 404, { error: "unknown node" });
      if (r !== "5s" && r !== "1m") return sendJSON(res, 400, { error: "res must be 5s or 1m" });
      return sendJSON(res, 200, history(node, r));
    }
    if (p === "/api/stream") {
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store", connection: "keep-alive" });
      res.write(`retry: 2000\n\n`);
      if (!paused) res.write(`event: snapshot\ndata: ${JSON.stringify(wobble(fixture, seq))}\n\n`);
      streams.add(res);
      req.on("close", () => streams.delete(res));
      return;
    }
    return sendJSON(res, 404, { error: "not found" });
  }

  if (p === "/") {
    if (!authed) { res.writeHead(302, { location: "/login" }); return res.end(); }
    return serveFile(res, join(STATIC, "index.html"));
  }

  const file = normalize(join(STATIC, decodeURIComponent(p)));
  if (!file.startsWith(STATIC + "/")) { res.writeHead(400); return res.end(); }
  if (!p.startsWith("/assets/") && !["/favicon.ico", "/robots.txt"].includes(p)) {
    res.writeHead(404); return res.end("not found");
  }
  return serveFile(res, file);
});

server.listen(PORT, () => {
  console.log(`obs_factor dev server on http://localhost:${PORT}  fixture=${fixtureName}  auth=${AUTH ? `password "${PASSWORD}"` : "off"}`);
});
