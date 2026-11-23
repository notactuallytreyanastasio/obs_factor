// The log explorer: every log line this page can see, in one searchable
// list. Two kinds of log feed it, both real and both read whole:
//
// - service:observer, the observer's own Logger output: the "logs" channel
//   on the page's socket (bus.js). The join reply is the last 2000 events
//   the observer keeps (or, on a rejoin, those after the last id we have),
//   then each new event is pushed as it is logged;
// - service:builder, each build's job log from the builder: the feed
//   builds:<id>:log (the whole log), one per build on the floor, left on the
//   second read after the floor says the job has finished (the first could
//   have been fetched just before it did).
//
// Builder lines have no level (they're program output: git, docker, the
// agent), so their level is "unset" rather than a guess.
//
// Search syntax, close to Datadog's:
//   host not found            free text: every word must appear in the message
//   "host not found"          an exact phrase
//   /time(d)? out/            a regular expression (case-insensitive)
//   level:error               an attribute; @level:error works too
//   source:dock*  job:deci-*  wildcards
//   level:(warning OR error)  any of several values
//   -source:docker  NOT x     exclude
//   a OR b                    either (binds tighter than the implicit AND)
//   line:>100  line:<=20      numeric comparisons
// Facet checkboxes on the left are separate filters, shown as pills, and
// each facet's counts are computed without its own filter (so you can see
// what you'd get by changing it).

import { esc } from "./fmt.js";
import * as bus from "./bus.js";

const $ = (id) => document.getElementById(id);
const LEVELS = ["emergency", "alert", "critical", "error", "warning", "notice", "info", "debug", "unset"];
const LEVEL_COLOR = { emergency: "#ff4d4d", alert: "#ff4d4d", critical: "#ff4d4d", error: "#ff4d4d", warning: "#ff9f1c", notice: "#f2c94c", info: "#7fe0ff", debug: "#5d6579", unset: "#8b93a7" };
const FACETS = [["level", "Level"], ["service", "Service"], ["source", "Source"], ["event", "Event"], ["node", "Node"], ["job", "Build"], ["step", "Step"], ["module", "Module"], ["domain", "Domain"]];
const RANGES = [["5m", 5 * 60e3], ["15m", 15 * 60e3], ["1h", 3600e3], ["4h", 4 * 3600e3], ["1d", 86400e3], ["all", null]];
const PAGE = 300;

// ---- query -------------------------------------------------------------------

function tokenize(q) {
  const out = [];
  let i = 0;
  while (i < q.length) {
    const c = q[i];
    if (/\s/.test(c)) { i++; continue; }
    if (c === "(" || c === ")") { out.push({ t: c }); i++; continue; }
    let neg = false;
    if (c === "-" && i + 1 < q.length && !/\s/.test(q[i + 1])) { neg = true; i++; }
    // key: prefix
    let key = null;
    const km = /^@?([A-Za-z_][\w.]*):/.exec(q.slice(i));
    if (km) { key = km[1]; i += km[0].length; }
    let val, kind = "word";
    if (q[i] === '"') {
      const j = q.indexOf('"', i + 1);
      val = q.slice(i + 1, j < 0 ? q.length : j); kind = "phrase"; i = j < 0 ? q.length : j + 1;
    } else if (q[i] === "/" && !key) {
      // ends at the next unescaped slash: /GET \/api\// is one regex
      let j = i + 1;
      while (j < q.length && !(q[j] === "/" && q[j - 1] !== "\\")) j++;
      if (j < q.length) { val = q.slice(i + 1, j).replace(/\\\//g, "/"); kind = "regex"; i = j + 1; } else { val = "/"; i++; }
    } else if (q[i] === "(" && key) {
      out.push({ t: "key", key, neg }); continue; // the group follows as tokens
    } else {
      let j = i;
      while (j < q.length && !/[\s()]/.test(q[j])) j++;
      val = q.slice(i, j); i = j;
    }
    if (!key && !neg && (val === "OR" || val === "AND" || val === "NOT") && kind === "word") { out.push({ t: val }); continue; }
    out.push({ t: "term", key, neg, val, kind });
  }
  return out;
}

// -> list of AND-ed clauses; a clause is a term or {or: [terms]}.
export function parse(q) {
  const toks = tokenize(q);
  const clauses = [];
  let i = 0, pendingOr = false, pendingNot = false, error = null;
  const push = (c) => {
    if (pendingNot) { c = { ...c, neg: !c.neg }; pendingNot = false; }
    if (pendingOr && clauses.length) { const prev = clauses.pop(); clauses.push({ or: [...(prev.or ?? [prev]), c] }); }
    else clauses.push(c);
    pendingOr = false;
  };
  while (i < toks.length) {
    const t = toks[i++];
    if (t.t === "OR") { pendingOr = true; continue; }
    if (t.t === "AND") continue;
    if (t.t === "NOT") { pendingNot = true; continue; }
    if (t.t === "key") {
      // key:( v1 OR v2 ... )
      if (toks[i]?.t !== "(") { error = `expected ( after ${t.key}:`; break; }
      i++;
      const vals = [];
      while (i < toks.length && toks[i].t !== ")") { const v = toks[i++]; if (v.t === "term") vals.push({ val: v.val, kind: v.kind }); }
      if (toks[i]?.t !== ")") error = `missing ) after ${t.key}:(`;
      i++;
      push({ key: t.key, neg: t.neg, any: vals });
      continue;
    }
    if (t.t === "(" || t.t === ")") continue;
    if (t.val === "") continue;
    push(t);
  }
  return { clauses, error };
}

const globRe = (v) => new RegExp(`^${v.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}$`, "i");
const cache = new Map();
function matcher(val, kind, isKey) {
  const k = `${kind}|${isKey}|${val}`;
  if (cache.has(k)) return cache.get(k);
  let fn;
  if (kind === "regex") {
    try { const re = new RegExp(val, "i"); fn = (s) => re.test(s); } catch { fn = () => false; }
  } else if (isKey) {
    const cmp = /^(>=|<=|>|<)(-?\d+(?:\.\d+)?)$/.exec(val);
    if (cmp && kind === "word") {
      const n = +cmp[2];
      fn = (s) => { const x = +s; return s !== "" && !isNaN(x) && (cmp[1] === ">" ? x > n : cmp[1] === "<" ? x < n : cmp[1] === ">=" ? x >= n : x <= n); };
    } else if (val.includes("*")) { const re = globRe(val); fn = (s) => re.test(s); }
    else { const lo = val.toLowerCase(); fn = (s) => s.toLowerCase() === lo; }
  } else if (val.includes("*")) { const re = new RegExp(val.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*"), "i"); fn = (s) => re.test(s); }
  else { const lo = val.toLowerCase(); fn = (s) => s.toLowerCase().includes(lo); }
  if (cache.size > 500) cache.clear();
  cache.set(k, fn);
  return fn;
}

function field(e, key) {
  if (key === "message" || key === "msg") return e.message;
  if (key === "level" || key === "status") return e.level;
  if (key === "service") return e.service;
  const v = e.attrs[key];
  return v == null ? null : String(v);
}

function test(e, c) {
  if (c.or) return c.or.some((x) => test(e, x));
  let hit;
  if (c.any) {
    const f = field(e, c.key);
    hit = f != null && c.any.some((v) => matcher(v.val, v.kind, true)(f));
  } else if (c.key) {
    const f = field(e, c.key);
    hit = c.val === "*" ? f != null : f != null && matcher(c.val, c.kind, true)(f);
  } else {
    hit = matcher(c.val, c.kind, false)(e.haystack);
  }
  return c.neg ? !hit : hit;
}

// free-text terms, for highlighting
function highlightTerms(clauses) {
  const out = [];
  const walk = (c) => { if (c.or) c.or.forEach(walk); else if (!c.key && !c.neg && !c.any && c.kind !== "regex" && !c.val.includes("*")) out.push(c.val); };
  clauses.forEach(walk);
  return out.filter((t) => t.length > 1);
}

// ---- time --------------------------------------------------------------------

const pad = (n, w = 2) => String(n).padStart(w, "0");
// withDate: true for the full date, "short" for MM-DD; secOnly drops the
// milliseconds (builder lines are only stamped to the second)
function stamp(ms, withDate, secOnly = false) {
  const d = new Date(ms);
  const t = `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}${secOnly ? "" : `.${pad(d.getUTCMilliseconds(), 3)}`}`;
  if (withDate === "short") return `${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${t}`;
  return withDate ? `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${t}` : t;
}

// ---- the modal ---------------------------------------------------------------

export class LogExplorer {
  constructor({ snap }) {
    this.snap = snap;
    this.events = [];
    this.byKey = new Set();
    this.lastId = 0;
    this.kept = null;
    this.builds = new Map(); // job id -> {count, status, error}
    this.query = "";
    this.sel = {}; // facet -> Set of values
    this.range = "all";
    this.brush = null; // [t0, t1] from the histogram
    this.limit = PAGE;
    this.picked = null;
    this.tail = true;
    this.errs = new Map(); // what failed to load -> why
    this.obsUnsub = null;
    this.buildUnsubs = new Map(); // job id -> unsubscribe
    this.renderTimer = null;
    this.build();
  }

  build() {
    const el = document.createElement("div");
    el.id = "logx";
    el.hidden = true;
    el.innerHTML = `<div class="lx-back" data-close></div>
      <div class="lx" role="dialog" aria-modal="true" aria-label="Log explorer">
        <header class="lx-top">
          <h3>Logs</h3>
          <div class="lx-search"><span class="lx-ic" aria-hidden="true">⌕</span>
            <input type="search" spellcheck="false" autocomplete="off" placeholder='Search: level:error -source:docker "host not found"' aria-label="Search logs">
            <button type="button" class="lx-help" aria-label="Search syntax" aria-expanded="false">?</button></div>
          <div class="lx-ranges" role="group" aria-label="Time range">${RANGES.map(([k]) => `<button type="button" data-range="${k}">${k}</button>`).join("")}</div>
          <label class="lx-tail"><input type="checkbox" checked> live</label>
          <button type="button" class="iconbtn lx-x" data-close aria-label="Close">×</button>
        </header>
        <div class="lx-syntax" hidden>
          <code>host not found</code> all words · <code>"host not found"</code> phrase · <code>/time(d)? out/</code> regex ·
          <code>level:error</code> attribute · <code>source:dock*</code> wildcard · <code>level:(warning OR error)</code> any of ·
          <code>-source:docker</code> exclude · <code>a OR b</code> either · <code>line:&gt;100</code> compare · <code>@attr:*</code> has attribute.
          Click a line to see its attributes; + and − on any attribute filter by it. <kbd>/</kbd> search, <kbd>↑</kbd><kbd>↓</kbd> move, <kbd>Esc</kbd> close.
        </div>
        <div class="lx-pills"></div>
        <div class="lx-body">
          <aside class="lx-facets" aria-label="Facets"></aside>
          <section class="lx-main">
            <div class="lx-hist"><canvas height="64"></canvas><div class="lx-histnote"></div></div>
            <div class="lx-status"></div>
            <div class="lx-list" tabindex="0"></div>
          </section>
          <aside class="lx-detail" hidden></aside>
        </div>
      </div>`;
    document.body.appendChild(el);
    this.el = el;
    this.input = el.querySelector(".lx-search input");
    this.facetsEl = el.querySelector(".lx-facets");
    this.listEl = el.querySelector(".lx-list");
    this.detailEl = el.querySelector(".lx-detail");
    this.statusEl = el.querySelector(".lx-status");
    this.pillsEl = el.querySelector(".lx-pills");
    this.canvas = el.querySelector(".lx-hist canvas");

    el.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => this.close()));
    let deb;
    this.input.addEventListener("input", () => { clearTimeout(deb); deb = setTimeout(() => { this.query = this.input.value; this.limit = PAGE; this.render(); }, 120); });
    el.querySelector(".lx-help").addEventListener("click", (e) => {
      const s = el.querySelector(".lx-syntax"); s.hidden = !s.hidden; e.currentTarget.setAttribute("aria-expanded", String(!s.hidden));
    });
    el.querySelector(".lx-ranges").addEventListener("click", (e) => {
      const b = e.target.closest("[data-range]");
      if (b) { this.range = b.dataset.range; this.brush = null; this.limit = PAGE; this.render(); }
    });
    el.querySelector(".lx-tail input").addEventListener("change", (e) => { this.tail = e.target.checked; this.tail ? this.sync() : this.stop(); this.renderStatus(); });
    this.facetsEl.addEventListener("change", (e) => {
      const cb = e.target.closest("input[data-facet]");
      if (!cb) return;
      const set = this.sel[cb.dataset.facet] ??= new Set();
      if (cb.checked) set.add(cb.value); else set.delete(cb.value);
      if (!set.size) delete this.sel[cb.dataset.facet];
      this.limit = PAGE; this.render();
    });
    this.facetsEl.addEventListener("click", (e) => {
      const only = e.target.closest("[data-only]");
      if (only) { e.preventDefault(); this.sel[only.dataset.only] = new Set([only.dataset.v]); this.limit = PAGE; this.render(); }
    });
    this.pillsEl.addEventListener("click", (e) => {
      const p = e.target.closest("[data-pill]");
      if (!p) return;
      const [k, v] = JSON.parse(p.dataset.pill);
      if (k === "@range") this.brush = null;
      else if (k === "@query") { this.query = ""; this.input.value = ""; }
      else { this.sel[k]?.delete(v); if (!this.sel[k]?.size) delete this.sel[k]; }
      this.render();
    });
    this.listEl.addEventListener("click", (e) => {
      if (e.target.closest(".lx-more")) { this.limit += PAGE; this.renderList(); return; }
      const row = e.target.closest("[data-k]");
      if (row) this.pick(row.dataset.k === this.picked ? null : row.dataset.k);
    });
    this.detailEl.addEventListener("click", (e) => {
      const b = e.target.closest("[data-act]");
      if (!b) return;
      const { act, k, v } = b.dataset;
      if (act === "close") return this.pick(null);
      if (act === "copy") { navigator.clipboard?.writeText(v); b.textContent = "copied"; return; }
      if (act === "context") { this.contextOf(k); return; }
      const facet = FACETS.some(([f]) => f === k);
      if (act === "add" && facet) { (this.sel[k] ??= new Set()).add(v); }
      else this.addQuery(`${act === "not" ? "-" : ""}${k}:${/[\s()"]/.test(v) || v === "" ? JSON.stringify(v) : v}`);
      this.limit = PAGE; this.render();
    });
    this.brushing();
    // capture: runs before the inspector's and the tour's Escape handlers
    window.addEventListener("keydown", (e) => this.key(e), true);
    window.addEventListener("resize", () => { if (!this.el.hidden) this.drawHist(); });
  }

  addQuery(term) {
    this.query = `${this.query.trim()} ${term}`.trim();
    this.input.value = this.query;
  }

  // Show what happened around a line: clear every filter, keep its service,
  // and put the time range at a minute either side of it.
  contextOf(key) {
    const e = this.events.find((x) => x.key === key);
    if (!e) return;
    this.query = ""; this.input.value = "";
    this.sel = { service: new Set([e.service]) };
    if (e.attrs.job) this.sel.job = new Set([e.attrs.job]);
    this.brush = [e.at - 60e3, e.at + 60e3];
    this.limit = PAGE * 4;
    this.render();
    this.listEl.querySelector(`[data-k="${CSS.escape(key)}"]`)?.scrollIntoView({ block: "center" });
  }

  get isOpen() { return !this.el.hidden; }

  // preset: {service: [...], job: [...], query: "..."}
  async open(preset = {}) {
    this.el.hidden = false;
    document.body.classList.add("logx-open");
    this.sel = {};
    for (const [k, vals] of Object.entries(preset)) if (k !== "query" && vals?.length) this.sel[k] = new Set(vals);
    this.query = preset.query ?? "";
    this.input.value = this.query;
    this.brush = null; this.limit = PAGE; this.picked = null;
    this.detailEl.hidden = true;
    this.statusEl.textContent = "Loading…";
    this.render();
    await this.sync();
    setTimeout(() => this.input.focus({ preventScroll: true }), 30);
  }

  close() {
    this.el.hidden = true;
    document.body.classList.remove("logx-open");
    this.stop();
  }

  // ---- loading ---------------------------------------------------------------

  add(e) {
    if (this.byKey.has(e.key)) return;
    this.byKey.add(e.key);
    e.haystack = `${e.message} ${e.attrs.module ?? ""}`;
    this.events.push(e);
  }

  get loadErr() { return [...this.errs.values()]; }

  // Subscribes to the observer's log and to each build on the floor that
  // we have not read whole. Resolves once the observer log's join replied.
  sync() {
    let first = Promise.resolve();
    if (!this.obsUnsub) {
      first = new Promise((resolve) => {
        this.obsUnsub = bus.subscribe("logs", (ev, p) => { if (ev === "events") this.takeObserver(p.events); }, {
          // a rejoin after a reconnect asks only for what it missed
          params: () => ({ after: this.lastId }),
          onJoin: (r) => {
            this.kept = r.kept; this.errs.delete("observer");
            this.takeObserver(r.events);
            this.renderNow();
            if (!this.tail) this.stop();
            resolve();
          },
          onError: (reason) => { this.errs.set("observer", `observer log: ${reason}`); this.obsUnsub = null; this.renderStatus(); resolve(); },
        });
      });
    }
    this.syncBuilds();
    return first;
  }

  // the floor changed (main.js calls this per snapshot): builds that appeared
  onSnapshot() { if (this.isOpen && this.tail) this.syncBuilds(); }

  syncBuilds() {
    const snap = this.snap();
    for (const n of snap?.nodes ?? []) {
      const id = n.build?.id, status = n.build?.status;
      if (!id || this.buildUnsubs.has(id)) continue;
      const known = this.builds.get(id);
      // a finished job's log doesn't change: read it once
      if (known && known.status !== "running" && status !== "running") continue;
      let afterDone = 0;
      const take = (p) => {
        if (!p.at) return;
        if (p.error) { this.errs.set(`build ${id}`, `build ${id}: ${p.error}`); this.renderStatus(); return; }
        this.errs.delete(`build ${id}`);
        const now = this.snap()?.nodes.find((x) => x.build?.id === id)?.build.status ?? "gone";
        if (this.takeBuild(id, p.data.log, now)) this.renderSoon();
        if (now !== "running" && ++afterDone >= 2) { this.buildUnsubs.get(id)?.(); this.buildUnsubs.delete(id); }
      };
      this.buildUnsubs.set(id, bus.subscribe(`builds:${id}:log`, (ev, p) => ev === "feed" && take(p), {
        onJoin: take,
        onError: (reason) => { this.errs.set(`build ${id}`, `build ${id}: ${reason}`); this.renderStatus(); },
      }));
    }
  }

  stop() {
    this.obsUnsub?.(); this.obsUnsub = null;
    for (const u of this.buildUnsubs.values()) u();
    this.buildUnsubs.clear();
  }

  takeObserver(events) {
    let added = 0;
    for (const ev of events) {
      if (ev.id <= this.lastId && this.byKey.has(`o:${ev.id}`)) continue;
      const attrs = { ...ev.attrs };
      if (ev.where) attrs.module = ev.where;
      if (ev.pid) attrs.pid = ev.pid;
      this.add({ key: `o:${ev.id}`, id: ev.id, at: ev.at, level: ev.level, service: "observer", message: ev.text, attrs });
      if (ev.id > this.lastId) this.lastId = ev.id;
      added++;
    }
    // tailing keeps lines the ring has since dropped; cap what the page holds
    if (added) { this.trimObserver(10_000); this.renderSoon(); }
  }

  trimObserver(cap) {
    const obs = this.events.filter((e) => e.service === "observer");
    if (obs.length <= cap) return;
    const drop = new Set(obs.slice(0, obs.length - cap).map((e) => e.key));
    this.events = this.events.filter((e) => !drop.has(e.key));
    drop.forEach((k) => this.byKey.delete(k));
  }

  takeBuild(id, log, status) {
    const had = this.builds.get(id)?.count ?? 0;
    log.forEach((l, n) => {
      if (n < had) return;
      this.add({ key: `b:${id}:${n}`, at: Date.parse(l.t), level: "unset", service: "builder", message: l.line, attrs: { job: id, step: l.step } });
    });
    this.builds.set(id, { count: log.length, status });
    return log.length - had;
  }

  // pushes come one event at a time: draw at most every 250 ms
  renderSoon() {
    if (this.renderTimer || !this.isOpen) return;
    this.renderTimer = setTimeout(() => this.renderNow(), 250);
  }

  renderNow() {
    clearTimeout(this.renderTimer); this.renderTimer = null;
    this.events.sort((a, b) => a.at - b.at || (a.id ?? 0) - (b.id ?? 0));
    this.render();
  }

  // ---- filtering ---------------------------------------------------------------

  timeWindow() {
    if (this.brush) return this.brush;
    const ms = RANGES.find(([k]) => k === this.range)[1];
    return ms ? [Date.now() - ms, Infinity] : [-Infinity, Infinity];
  }

  // events in the time window matching the query and every facet but `except`
  filter(except = null, ignoreTime = false) {
    const [t0, t1] = ignoreTime ? [-Infinity, Infinity] : this.timeWindow();
    const sel = Object.entries(this.sel).filter(([k]) => k !== except);
    const clauses = this.parsed.clauses;
    return this.events.filter((e) =>
      e.at >= t0 && e.at <= t1 &&
      sel.every(([k, set]) => set.has(field(e, k) ?? "(none)")) &&
      clauses.every((c) => test(e, c)));
  }

  // ---- rendering ---------------------------------------------------------------

  render() {
    this.parsed = parse(this.query);
    this.results = this.filter();
    this.el.querySelectorAll("[data-range]").forEach((b) => b.setAttribute("aria-pressed", String(!this.brush && b.dataset.range === this.range)));
    this.renderPills();
    this.renderFacets();
    this.drawHist();
    this.renderStatus();
    this.renderList();
    if (this.picked && !this.byKey.has(this.picked)) this.pick(null);
  }

  renderPills() {
    const pills = [];
    if (this.brush) pills.push([["@range", null], `${stamp(this.brush[0], true)} → ${stamp(this.brush[1], true)}`]);
    for (const [k, set] of Object.entries(this.sel)) for (const v of set) pills.push([[k, v], `${k}:${v}`]);
    this.pillsEl.innerHTML = pills.map(([d, t]) => `<button type="button" class="lx-pill" data-pill="${esc(JSON.stringify(d))}">${esc(t)} <span aria-hidden="true">×</span></button>`).join("");
    this.pillsEl.hidden = !pills.length;
  }

  renderFacets() {
    const html = FACETS.map(([k, label]) => {
      const base = this.filter(k);
      const counts = new Map();
      for (const e of base) { const v = field(e, k) ?? "(none)"; counts.set(v, (counts.get(v) ?? 0) + 1); }
      for (const v of this.sel[k] ?? []) if (!counts.has(v)) counts.set(v, 0);
      if (!counts.size || (counts.size === 1 && counts.has("(none)") && !this.sel[k])) return "";
      let rows = [...counts.entries()];
      rows.sort(k === "level" ? (a, b) => LEVELS.indexOf(a[0]) - LEVELS.indexOf(b[0]) : (a, b) => b[1] - a[1] || String(a[0]).localeCompare(b[0]));
      const more = rows.length > 12 ? rows.length - 12 : 0;
      rows = rows.slice(0, 12);
      const max = Math.max(...rows.map((r) => r[1]), 1);
      return `<div class="lx-facet"><h4>${label}</h4>${rows.map(([v, n]) => `<label class="lx-fv" title="${esc(`${k}:${v}`)}">
          <input type="checkbox" data-facet="${k}" value="${esc(v)}"${this.sel[k]?.has(v) ? " checked" : ""}>
          ${k === "level" ? `<span class="lx-dot" style="background:${LEVEL_COLOR[v] ?? "#8b93a7"}"></span>` : ""}<span class="v">${esc(v)}</span>
          <span class="bar"><i style="width:${(n / max) * 100}%"></i></span><span class="n">${n}</span>
          <a href="#" data-only="${k}" data-v="${esc(v)}" class="only">only</a></label>`).join("")}${more ? `<div class="lx-fmore">+${more} more: search ${esc(k)}:value</div>` : ""}</div>`;
    }).join("");
    this.facetsEl.innerHTML = html || '<p class="note">No facets yet.</p>';
  }

  renderStatus() {
    const obs = this.events.filter((e) => e.service === "observer").length;
    const err = this.parsed?.error ? `<span class="err">query: ${esc(this.parsed.error)}</span> · ` : "";
    const load = this.loadErr.length ? `<span class="err">${this.loadErr.map(esc).join(" · ")}</span> · ` : "";
    const builds = [...this.builds].map(([id, b]) => `${id}: ${b.count} lines`).join("\n");
    this.statusEl.innerHTML = `${err}${load}<b>${(this.results?.length ?? 0).toLocaleString()}</b> of ${this.events.length.toLocaleString()} lines
      <span class="unk" title="The observer keeps its last ${this.kept ?? "?"} events; while tailing, this page keeps up to 10,000.\n${esc(builds)}">· ${obs} observer, ${(this.events.length - obs).toLocaleString()} from ${this.builds.size} build${this.builds.size === 1 ? "" : "s"}${this.tail ? ' · <span class="lx-live">live</span>' : ""}</span>`;
  }

  renderList() {
    const rows = this.results.slice().reverse(); // newest first
    const terms = highlightTerms(this.parsed.clauses);
    const re = terms.length ? new RegExp(`(${terms.map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "gi") : null;
    const today = new Date().toISOString().slice(0, 10);
    const hl = (s) => (re ? esc(s).replace(re, "<mark>$1</mark>") : esc(s));
    const shown = rows.slice(0, this.limit);
    this.listEl.innerHTML = shown.length
      ? shown.map((e) => {
          const tag = e.service === "builder" ? `${e.attrs.job} · ${e.attrs.step}` : e.attrs.source ?? e.attrs.event ?? e.attrs.module?.replace(/^ObsFactor(Web)?\./, "") ?? "";
          const withDate = new Date(e.at).toISOString().slice(0, 10) !== today;
          return `<div class="lx-row${e.key === this.picked ? " on" : ""}" data-k="${esc(e.key)}" style="--lc:${LEVEL_COLOR[e.level] ?? "#8b93a7"}">
            <span class="t" title="${stamp(e.at, true, e.service === "builder")} UTC">${stamp(e.at, withDate && "short", e.service === "builder")}</span><span class="lv">${esc(e.level)}</span><span class="svc">${esc(e.service)}</span>
            <span class="msg">${hl(e.message.length > 600 ? e.message.slice(0, 600) + "…" : e.message)}${tag ? ` <span class="tag">${esc(tag)}</span>` : ""}</span></div>`;
        }).join("") + (rows.length > shown.length ? `<button type="button" class="lx-more">Show ${Math.min(PAGE, rows.length - shown.length)} more of ${rows.length - shown.length}</button>` : "")
      : `<p class="note lx-empty">${this.events.length ? "No lines match. Widen the time range or remove a filter." : "No log lines loaded."}</p>`;
  }

  pick(key) {
    this.picked = key;
    this.listEl.querySelectorAll(".lx-row.on").forEach((r) => r.classList.remove("on"));
    if (!key) { this.detailEl.hidden = true; return; }
    const row = this.listEl.querySelector(`[data-k="${CSS.escape(key)}"]`);
    row?.classList.add("on");
    row?.scrollIntoView({ block: "nearest" });
    const e = this.events.find((x) => x.key === key);
    if (!e) { this.detailEl.hidden = true; return; }
    const attrs = [["level", e.level], ["service", e.service], ...Object.entries(e.attrs).sort((a, b) => a[0].localeCompare(b[0]))];
    const v = (x) => String(x);
    this.detailEl.hidden = false;
    this.detailEl.innerHTML = `<div class="lx-dhead"><b>${stamp(e.at, true, e.service === "builder")} UTC</b><button type="button" class="iconbtn" data-act="close" aria-label="Close details">×</button></div>
      <pre class="lx-dmsg">${esc(e.message)}</pre>
      <div class="lx-dacts"><button type="button" data-act="copy" data-v="${esc(e.message)}">copy message</button><button type="button" data-act="context" data-k="${esc(e.key)}">±1 min around it</button></div>
      <table class="lx-attrs">${attrs.map(([k, x]) => `<tr><th>${esc(k)}</th><td>${esc(v(x))}</td>
        <td class="acts"><button type="button" data-act="add" data-k="${esc(k)}" data-v="${esc(v(x))}" title="only lines with ${esc(k)}:${esc(v(x))}">+</button><button type="button" data-act="not" data-k="${esc(k)}" data-v="${esc(v(x))}" title="exclude ${esc(k)}:${esc(v(x))}">−</button></td></tr>`).join("")}</table>`;
  }

  // ---- histogram ---------------------------------------------------------------

  histSpan() {
    const [w0, w1] = this.timeWindow();
    const ats = this.results.map((e) => e.at);
    // a preset window ends now; "all" spans the matching lines themselves
    const lo = isFinite(w0) ? w0 : ats.length ? Math.min(...ats) : Date.now() - 3600e3;
    const hi = isFinite(w1) ? w1 : isFinite(w0) ? Date.now() : ats.length ? Math.max(...ats) + 1000 : Date.now();
    return [lo, hi > lo ? hi : lo + 1000];
  }

  drawHist() {
    const cv = this.canvas;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const W = cv.clientWidth || 600, H = 64;
    cv.width = W * dpr; cv.height = H * dpr;
    const ctx = cv.getContext("2d");
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, W, H);
    if (!this.results) return;
    const [t0, t1] = (this.span = this.histSpan());
    const n = Math.max(20, Math.min(120, Math.floor(W / 7)));
    const bw = (t1 - t0) / n;
    const buckets = Array.from({ length: n }, () => ({}));
    for (const e of this.results) {
      const i = Math.min(n - 1, Math.max(0, Math.floor((e.at - t0) / bw)));
      buckets[i][e.level] = (buckets[i][e.level] ?? 0) + 1;
    }
    const tot = buckets.map((b) => Object.values(b).reduce((a, x) => a + x, 0));
    const max = Math.max(1, ...tot);
    const colW = W / n;
    buckets.forEach((b, i) => {
      let y = H - 12;
      for (const lv of [...LEVELS].reverse()) {
        const c = b[lv];
        if (!c) continue;
        const h = Math.max(1, (c / max) * (H - 18));
        ctx.fillStyle = LEVEL_COLOR[lv];
        ctx.fillRect(i * colW + 0.5, y - h, Math.max(1, colW - 1.5), h);
        y -= h;
      }
    });
    ctx.fillStyle = "rgba(200,206,220,0.55)"; ctx.font = "10px ui-monospace, Menlo, monospace"; ctx.textBaseline = "bottom";
    ctx.fillText(stamp(t0, true).slice(0, 19), 2, H);
    ctx.textAlign = "right"; ctx.fillText(stamp(t1, true).slice(0, 19), W - 2, H); ctx.textAlign = "left";
    ctx.textBaseline = "top"; ctx.fillText(`max ${max}/bar · ${duration(bw)} per bar`, 2, 0);
    if (this.drag) {
      const [a, b2] = [Math.min(this.drag.x0, this.drag.x1), Math.max(this.drag.x0, this.drag.x1)];
      ctx.fillStyle = "rgba(242,201,76,0.18)"; ctx.fillRect(a, 0, b2 - a, H - 12);
      ctx.strokeStyle = "rgba(242,201,76,0.8)"; ctx.strokeRect(a + 0.5, 0.5, b2 - a, H - 13);
    }
    this.el.querySelector(".lx-histnote").textContent = "drag to zoom into a time range";
  }

  brushing() {
    const cv = this.canvas;
    const x = (e) => e.clientX - cv.getBoundingClientRect().left;
    cv.addEventListener("pointerdown", (e) => { cv.setPointerCapture(e.pointerId); this.drag = { x0: x(e), x1: x(e) }; });
    cv.addEventListener("pointermove", (e) => { if (this.drag) { this.drag.x1 = x(e); this.drawHist(); } });
    cv.addEventListener("pointerup", () => {
      const d = this.drag; this.drag = null;
      if (!d || Math.abs(d.x1 - d.x0) < 4) { this.drawHist(); return; }
      const W = cv.clientWidth, [t0, t1] = this.span;
      const at = (px) => t0 + (Math.max(0, Math.min(W, px)) / W) * (t1 - t0);
      this.brush = [at(Math.min(d.x0, d.x1)), at(Math.max(d.x0, d.x1))];
      this.limit = PAGE;
      this.render();
    });
    cv.addEventListener("dblclick", () => { this.brush = null; this.render(); });
  }

  // ---- keys --------------------------------------------------------------------

  key(e) {
    if (!this.isOpen) return;
    const typing = e.target.closest?.("input, textarea, select");
    if (e.key === "Escape") {
      e.stopImmediatePropagation();
      if (typing && this.input.value && e.target === this.input) return; // the search box clears itself
      if (this.picked) this.pick(null); else this.close();
      return;
    }
    if (e.key === "/" && !typing) { e.preventDefault(); this.input.focus(); this.input.select(); return; }
    if ((e.key === "ArrowDown" || e.key === "ArrowUp") && (!typing || e.target === this.input)) {
      e.preventDefault();
      const rows = [...this.listEl.querySelectorAll(".lx-row")];
      if (!rows.length) return;
      let i = rows.findIndex((r) => r.dataset.k === this.picked);
      i = i < 0 ? 0 : Math.max(0, Math.min(rows.length - 1, i + (e.key === "ArrowDown" ? 1 : -1)));
      this.pick(rows[i].dataset.k);
    }
  }
}

function duration(ms) {
  if (ms < 1000) return `${Math.round(ms)} ms`;
  if (ms < 60e3) return `${Math.round(ms / 1000)} s`;
  if (ms < 3600e3) return `${Math.round(ms / 60e3)} min`;
  return `${(ms / 3600e3).toFixed(1)} h`;
}
