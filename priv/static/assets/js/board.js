// The board: the floor as a trading floor would show it. Four pieces, all
// reading the same numbers, all following what is on screen (live, or the
// moment of the tape being replayed):
//
//   the index row   in the top bar: the box's headline numbers, each with
//                   its move over the last 5 minutes, green when the move
//                   is good for the box and red when it is bad
//   the chyron      over the timeline: LIVE or REPLAY, the top story (the
//                   worst fire, rotating through them), the clock
//   the crawl       under the chyron: every building's number and its move
//   the monitor     (Board, key b) one dense row per building: lamp, rate
//                   with a 15-minute sparkline, 5xx, p95, CPU, memory, move
//
// The numbers are the tape's per-node metrics (ObsFactor.Tape.series and
// each `tick` push on `tape`), so a replayed moment shows the board as it
// was then, not as it is now.

import * as bus from "./bus.js";
import { esc, num, bytes } from "./fmt.js";

const WINDOW = 15 * 60e3; // what the sparklines and moves look back over
const MOVE = 5 * 60e3; // a move is against this long ago
const ROTATE_MS = 5000;
const pad = (n) => String(n).padStart(2, "0");
const hms = (ms) => { const d = new Date(ms); return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`; };
const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const typing = (el) => el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
function ago(ms) { const m = Math.round(ms / 60e3); return m < 60 ? `${m}m` : m < 2880 ? `${Math.floor(m / 60)}h ${pad(m % 60)}m` : `${Math.floor(m / 1440)}d`; }

// which way is good: +1 more is good, -1 more is bad, 0 neither
const GOOD = { rps: 0, err_rps: -1, p95_ms: -1, avg_ms: -1, cpu_cores: -1, mem_bytes: -1, commits_per_s: 0, connections: -1, cpu_used_cores: -1, mem_used_bytes: -1, disk_used_pct: -1, in_flight: -1 };
const FMT = {
  rps: (v) => `${num(v)}/s`, err_rps: (v) => `${num(v)}/s`, p95_ms: (v) => `${num(v)} ms`, avg_ms: (v) => `${num(v)} ms`,
  cpu_cores: (v) => `${num(v)}c`, cpu_used_cores: (v) => `${num(v)}c`, mem_bytes: bytes, mem_used_bytes: bytes,
  disk_used_pct: (v) => `${num(v)}%`, commits_per_s: (v) => `${num(v)}/s`, connections: (v) => num(v), in_flight: (v) => num(v),
};
// the number a building is known by on the crawl and the monitor
const PRIMARY = ["rps", "commits_per_s", "cpu_used_cores", "mem_used_bytes", "disk_used_pct", "cpu_cores"];

export class Board {
  constructor(api) {
    this.api = api; // { timeline, go(id), closeOthers(), onToggle() }
    this.series = []; // [[at, {node: {key: n}}]], oldest first
    this.shown = null; this.shownAt = null;
    this.story = 0;
    this.el = document.getElementById("board");
    this.btn = document.getElementById("boardbtn");
    this.index = document.getElementById("indexrow");
    this.news = document.getElementById("news");
    this.news.innerHTML = `<div class="nw-chyron"><span class="nw-bug">LIVE</span><span class="nw-head"></span><span class="nw-clock"></span></div><div class="nw-crawl"><div class="nw-track"></div></div>`;
    this.btn.addEventListener("click", () => this.toggle());
    this.el.addEventListener("click", (e) => {
      if (e.target.closest("[data-a=close]")) return this.toggle(false);
      const r = e.target.closest("[data-node]");
      if (r) this.api.go(r.dataset.node);
    });
    this.news.addEventListener("click", (e) => { const s = e.target.closest("[data-node]"); if (s) this.api.go(s.dataset.node); });
    document.addEventListener("keydown", (e) => {
      if (e.key !== "b" || e.metaKey || e.ctrlKey || e.altKey || typing(e.target) || e.defaultPrevented) return;
      e.preventDefault(); this.toggle();
    });
    setInterval(() => { this.story++; this.renderChyron(); }, ROTATE_MS);
    setInterval(() => this.renderClock(), 1000);
    bus.subscribe("tape", (ev, t) => { if (ev === "tick") this.onTick(t); }, {
      onJoin: (r) => {
        if (r.error) return;
        document.body.classList.add("has-news");
        this.fetch(Date.now());
      },
    });
  }

  get open() { return !this.el.hidden; }

  toggle(open) {
    const on = open ?? this.el.hidden;
    if (on) this.api.closeOthers();
    this.el.hidden = !on;
    this.btn.setAttribute("aria-expanded", String(on));
    document.body.classList.toggle("board-open", on);
    if (on) this.renderMonitor();
    this.api.onToggle?.();
  }

  // ---- the numbers ---------------------------------------------------------

  fetch(end) {
    this.fetching = end;
    bus.push("tape", "series", { from: Math.round(end - WINDOW), to: Math.round(end), points: 180 })
      .then((r) => {
        if (this.fetching !== end) return;
        this.series = r.series;
        this.fetchedEnd = end;
        this.render();
      })
      .catch((e) => console.error(`obs_factor board: series: ${e.message}`));
  }

  onTick(t) {
    if (this.api.timeline.replaying || !t.metrics) return;
    this.series.push([t.at, t.metrics]);
    while (this.series.length && this.series[0][0] < t.at - WINDOW) this.series.shift();
  }

  // what is on screen changed: the board follows it
  onShown(snap, at) {
    this.shown = snap; this.shownAt = at;
    // replaying: the numbers are read again for a moment the series does not end at
    if (this.api.timeline.replaying && (this.fetchedEnd == null || Math.abs(at - this.fetchedEnd) > 15_000) && !this.wait) {
      this.wait = setTimeout(() => { this.wait = null; this.fetch(this.shownAt); }, this.api.timeline.playing ? 400 : 0);
    } else if (!this.api.timeline.replaying && this.fetchedEnd != null && this.fetchedEnd < Date.now() - 60_000 && this.wasReplaying) {
      this.fetch(Date.now()); // back to live: the live window again
    }
    this.wasReplaying = this.api.timeline.replaying;
    this.render();
  }

  // the points up to the moment on screen
  upTo() {
    const end = this.shownAt ?? Infinity;
    const pts = [];
    for (const p of this.series) if (p[0] <= end + 2500) pts.push(p);
    return pts;
  }

  value(pts, node, key) {
    for (let i = pts.length - 1; i >= 0; i--) { const v = pts[i][1][node]?.[key]; if (isNum(v)) return v; }
    return null;
  }

  // [now, then, change]: then is the value about MOVE ago
  move(pts, node, key) {
    const now = this.value(pts, node, key);
    if (now == null || !pts.length) return [now, null, null];
    const target = pts[pts.length - 1][0] - MOVE;
    let then = null;
    for (const p of pts) { if (p[0] >= target) { const v = p[1][node]?.[key]; if (isNum(v)) { then = v; break; } } }
    return [now, then, then == null ? null : now - then];
  }

  // ▲4.1% in the colour of whether that is good for the box
  delta(key, now, then) {
    if (now == null || then == null) return `<i class="bd-d flat">·</i>`;
    const d = now - then;
    const rel = then !== 0 ? d / Math.abs(then) : now !== 0 ? 1 : 0;
    if (Math.abs(rel) < 0.02) return `<i class="bd-d flat">▬</i>`;
    const good = GOOD[key] ?? 0;
    const cls = good === 0 ? "neu" : (d > 0) === (good > 0) ? "up" : "dn";
    const pct = then !== 0 ? `${Math.abs(rel * 100) >= 100 ? Math.round(Math.abs(rel * 100)) : Math.abs(rel * 100).toFixed(1)}%` : "new";
    return `<i class="bd-d ${cls}">${d > 0 ? "▲" : "▼"}${pct}</i>`;
  }

  // ---- drawing -----------------------------------------------------------

  render() {
    if (!this.shown) return;
    this.renderIndex();
    this.renderChyron();
    this.renderCrawl();
    if (this.open) this.renderMonitor();
  }

  nodesOf(kind) { return (this.shown?.nodes ?? []).filter((n) => n.kind === kind).map((n) => n.id); }

  renderIndex() {
    const pts = this.upTo();
    const s = this.shown;
    const sum = (ids, key) => { let t = null, th = null; for (const id of ids) { const [n, p] = this.move(pts, id, key); if (n != null) t = (t ?? 0) + n; if (p != null) th = (th ?? 0) + p; } return [t, th]; };
    const proxies = this.nodesOf("proxy");
    const dbs = this.nodesOf("db");
    const apps = (s.nodes ?? []).filter((n) => n.kind === "app").map((n) => n.id);
    // the worst p95 among the apps: the slowest door is the one people notice
    let p95 = [null, null], p95node = null;
    for (const id of apps) { const m = this.move(pts, id, "p95_ms"); if (m[0] != null && (p95[0] == null || m[0] > p95[0])) { p95 = m; p95node = id; } }
    const tiles = [
      ["REQ", "rps", this.move(pts, "internet", "rps")],
      ["5XX", "err_rps", sum(proxies, "err_rps")],
      ["P95", "p95_ms", p95, p95node && `slowest: ${this.label(p95node)}`],
      ["CPU", "cpu_used_cores", this.move(pts, "host-cpu", "cpu_used_cores")],
      ["MEM", "mem_used_bytes", this.move(pts, "host-mem", "mem_used_bytes")],
      ["DISK", "disk_used_pct", this.move(pts, "host-disk", "disk_used_pct")],
      ["DB", "commits_per_s", sum(dbs, "commits_per_s")],
      ["CONN", "connections", sum(dbs, "connections")],
    ];
    const alerts = (s.attention ?? []).filter((a) => a.severity === "alert").length;
    const warns = (s.attention ?? []).filter((a) => a.severity === "warn").length;
    const calm = this.calm();
    this.index.innerHTML = tiles.map(([l, key, [now, then], title]) =>
      `<span class="ix"${title ? ` title="${esc(title)}"` : ""}><b>${l}</b><em>${now == null ? "–" : FMT[key](now)}</em>${this.delta(key, now, then)}</span>`).join("") +
      `<span class="ix fire${alerts ? " on" : ""}"><b>FIRES</b><em>${alerts}</em><i class="bd-d ${warns ? "dn" : "flat"}">${warns ? `${warns} smoke` : "·"}</i></span>` +
      `<span class="ix calm${calm?.burning ? " burning" : ""}"><b>${calm?.burning ? "BURNING" : "CALM"}</b><em>${calm ? ago(calm.ms) + (calm.atLeast ? "+" : "") : "–"}</em></span>`;
  }

  // how long the floor has been calm, or burning, at the moment on screen:
  // read off the timeline's columns
  calm() {
    const idx = this.api.timeline.index;
    if (!idx?.buckets.length) return null;
    const at = this.shownAt ?? Date.now();
    const b = idx.buckets.filter((x) => x[0] <= at);
    if (!b.length) return null;
    const burning = b[b.length - 1][2] > 0;
    let i = b.length - 1;
    while (i > 0 && (b[i - 1][2] > 0) === burning) i--;
    // a run that reaches back to the first column is at least that long
    // ("8m+"): the tape, or the window, starts there
    return { burning, ms: at - b[i][0], atLeast: i === 0 };
  }

  label(id) { return this.shown?.nodes.find((n) => n.id === id)?.label ?? id; }

  renderChyron() {
    if (!this.shown) return;
    const s = this.shown;
    const replay = this.api.timeline.replaying;
    const bug = this.news.querySelector(".nw-bug");
    bug.textContent = replay ? "REPLAY" : "LIVE";
    bug.classList.toggle("replay", replay);
    const fires = [...(s.attention ?? [])].filter((a) => a.severity === "alert" || a.severity === "warn")
      .sort((a, b) => (a.severity === "alert" ? 0 : 1) - (b.severity === "alert" ? 0 : 1));
    const head = this.news.querySelector(".nw-head");
    const chy = this.news.querySelector(".nw-chyron");
    if (!fires.length) {
      const c = this.calm();
      const pts = this.upTo();
      const rps = this.value(pts, "internet", "rps");
      chy.dataset.level = "calm";
      head.innerHTML = `<b>ALL QUIET</b> <span>${c && !c.burning ? `calm for ${ago(c.ms)}${c.atLeast ? "+" : ""}` : "no fire on the floor"}${rps != null ? ` · ${num(rps)} req/s coming in` : ""} · ${s.nodes.length} buildings</span>`;
      return;
    }
    const f = fires[this.story % fires.length];
    const down = s.nodes.find((n) => n.id === f.node)?.status === "down";
    chy.dataset.level = f.severity;
    head.innerHTML = `<b data-node="${esc(f.node ?? "")}">${esc((f.node ? this.label(f.node) : "OBSERVER").toUpperCase())}${down ? " DOWN" : f.severity === "alert" ? " ON FIRE" : " SMOKING"}</b> <span>${esc(f.text)}</span>${fires.length > 1 ? ` <i>${(this.story % fires.length) + 1}/${fires.length}</i>` : ""}`;
  }

  renderClock() {
    const c = this.news.querySelector(".nw-clock");
    const at = this.api.timeline.replaying ? this.api.timeline.cursor : Date.now();
    if (at == null) return;
    c.innerHTML = `${hms(at)} <span>UTC ${new Date(at).toLocaleDateString("en-GB", { timeZone: "UTC", day: "numeric", month: "short" }).toUpperCase()}</span>`;
  }

  // buildings with a number, worst first, then busiest
  rows() {
    const pts = this.upTo();
    const heat = new Map();
    for (const a of this.shown.attention ?? []) if (a.node) heat.set(a.node, a.severity === "alert" || heat.get(a.node) === "alert" ? "alert" : "warn");
    const rows = [];
    for (const n of this.shown.nodes) {
      const key = PRIMARY.find((k) => this.value(pts, n.id, k) != null);
      if (!key) continue;
      const [now, then] = this.move(pts, n.id, key);
      rows.push({ n, key, now, then, heat: heat.get(n.id) ?? (n.status === "down" ? "alert" : null) });
    }
    const rank = (r) => (r.heat === "alert" ? 0 : r.heat === "warn" ? 1 : 2);
    return rows.sort((a, b) => rank(a) - rank(b) || (b.key === "rps" ? b.now : 0) - (a.key === "rps" ? a.now : 0) || a.n.label.localeCompare(b.n.label));
  }

  renderCrawl() {
    const rows = this.rows();
    const html = rows.map((r) => `<span class="cr${r.heat ? ` ${r.heat}` : ""}" data-node="${esc(r.n.id)}"><b>${esc(r.n.label.toUpperCase())}</b> ${FMT[r.key](r.now)} ${this.delta(r.key, r.now, r.then)}</span>`).join("");
    const track = this.news.querySelector(".nw-track");
    if (track.dataset.html === html) return;
    track.dataset.html = html;
    // twice, so the loop has no seam; the speed is per pixel, not per item
    track.innerHTML = `<div class="nw-run">${html}</div><div class="nw-run" aria-hidden="true">${html}</div>`;
    const w = track.firstElementChild.scrollWidth;
    if (Math.abs((this.crawlW ?? 0) - w) > 40) { this.crawlW = w; track.style.setProperty("--crawl-s", `${Math.max(20, w / 60)}s`); }
  }

  spark(node, key) {
    const pts = this.upTo().map(([t, m]) => [t, m[node]?.[key]]).filter(([, v]) => isNum(v));
    if (pts.length < 2) return `<svg class="sp" viewBox="0 0 80 16"></svg>`;
    const t0 = pts[0][0], t1 = pts[pts.length - 1][0] || t0 + 1;
    let lo = Infinity, hi = -Infinity;
    for (const [, v] of pts) { if (v < lo) lo = v; if (v > hi) hi = v; }
    const span = hi - lo || 1;
    const d = pts.map(([t, v], i) => `${i ? "L" : "M"}${(((t - t0) / (t1 - t0 || 1)) * 80).toFixed(1)},${(15 - ((v - lo) / span) * 14).toFixed(1)}`).join("");
    return `<svg class="sp" viewBox="0 0 80 16" preserveAspectRatio="none"><path d="${d}"/></svg>`;
  }

  renderMonitor() {
    if (!this.shown) { this.el.innerHTML = ""; return; }
    const pts = this.upTo();
    const cell = (id, key) => { const v = this.value(pts, id, key); return v == null ? `<td class="na">–</td>` : `<td>${FMT[key](v)}</td>`; };
    const rows = this.rows();
    const at = this.shownAt ? hms(this.shownAt) : "";
    this.el.innerHTML = `<div class="bd-head"><h3>Board</h3><span class="bd-at">${this.api.timeline.replaying ? "REPLAY" : "LIVE"} ${at} · ${rows.length} buildings · moves over 5m</span><button type="button" class="fi-x" data-a="close" aria-label="Close">×</button></div>
      <table><thead><tr><th></th><th>building</th><th class="r">rate</th><th>15m</th><th class="r">move</th><th class="r">5xx</th><th class="r">p95</th><th class="r">cpu</th><th class="r">mem</th></tr></thead><tbody>
      ${rows.map((r) => `<tr data-node="${esc(r.n.id)}" class="${r.heat ?? ""}"><td><span class="lamp ${esc(r.n.status)}"></span></td><td class="nm">${esc(r.n.label)}</td>
        <td class="r">${FMT[r.key](r.now)}</td><td>${this.spark(r.n.id, r.key)}</td><td class="r">${this.delta(r.key, r.now, r.then)}</td>
        ${cell(r.n.id, "err_rps")}${cell(r.n.id, "p95_ms")}${cell(r.n.id, "cpu_cores")}${cell(r.n.id, "mem_bytes")}</tr>`).join("")}
      </tbody></table>
      <p class="bd-foot">Rate is each building's own number: requests, commits, or what the host uses. Click a row to go there. <kbd>b</kbd> opens and closes.</p>`;
  }
}
