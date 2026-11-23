// Processes: :observer's Processes tab across every BEAM on the floor.
//
// Everything here comes over the page's one socket (bus.js), from the feeds
// docs/contract.md describes under Observer, "On the bus":
//
//   observer:<node>:<member or ->:procs:<sort>   the top 50 processes of one
//       BEAM by mailbox, memory or reductions (reductions within a 1 s
//       window, so "busy now"), one topic per source in scope;
//   observer:<node>:<member or ->:proc:<pid>     the process opened in the
//       detail pane, with Kill / GC / Exit(shutdown) pushed as "action" on
//       that topic;
//   actions                                      what anyone did, as it happens;
//   snapshots                                    which buildings report, and
//       their cluster members, so the sources follow the floor.
//
// A source is a reporting building (a node with `inside`), one per cluster
// member (inside.members[].address), or the observer's own VM (node
// "observer", which is not a building on the floor). Scope: one building,
// every reporting building, or the observer. Closing the panel or changing
// the scope or the sort leaves every feed it no longer shows; the server
// stops a feed 10 s after its last viewer.
//
// The metric lens (ProcLens) is separate: while it is on it watches
// procs:<metric> of every reporting source and lights the buildings whose
// worst process is past a threshold, through the page's lens owner (main.js).
//
// Search reuses the log explorer's parse() (logs.js), so the syntax is the
// same: words, "phrases", /regex/, key:value, key:glob*, -key:x, a OR b,
// key:(a OR b), and numeric comparisons, here with sizes:
//   mq:>100 node:marginalia* -status:waiting memory:>1MB name:Runs

import * as bus from "./bus.js";
import { parse } from "./logs.js";
import { esc, num, bytes } from "./fmt.js";

const $ = (id) => document.getElementById(id);
const WHO_KEY = "obs_factor.who"; // the same name missions.js signs with
const SCOPE_KEY = "obs_factor.procs.scope";
const LENS_METRIC_KEY = "obs_factor.procs.lens";
const RECENT_MAX = 300;
const ROWS_MAX = 600;
const OBSERVER = "observer";

const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); return true; } catch { return false; } },
};
const typing = (el) => !!el?.closest?.("input, textarea, select, [contenteditable=true]");

// The three things a feed can be ranked by, and what the lens calls bad.
export const METRICS = {
  message_queue_len: { label: "mailbox", col: "mq", fmt: (v) => num(v), warn: 100, alert: 1000, thr: "messages" },
  memory: { label: "memory", col: "memory", fmt: (v) => bytes(v), warn: 50 * 1024 ** 2, alert: 200 * 1024 ** 2, thr: "" },
  reductions: { label: "reductions/s", col: "rps", fmt: (v) => num(v), warn: 500_000, alert: 2_000_000, thr: "per second" },
};
const thresholds = (m) => `amber ≥ ${METRICS[m].fmt(METRICS[m].warn)}, red ≥ ${METRICS[m].fmt(METRICS[m].alert)}${METRICS[m].thr ? ` ${METRICS[m].thr}` : ""}`;

// ---- sources -----------------------------------------------------------------

const observerSource = () => ({ node: OBSERVER, member: null, label: "observer", sub: "this VM", onFloor: false });

// Every reporting building's BEAMs, from the floor as the observer sent it.
export function reportingSources(outer) {
  const out = [];
  for (const n of outer?.nodes ?? []) {
    if (!n.inside) continue;
    const members = (n.inside.members ?? []).filter((m) => m && m.address);
    if (members.length > 1) {
      for (const m of members) out.push({ node: n.id, member: m.address, label: n.label, sub: m.cluster?.node ?? m.address, onFloor: true });
    } else out.push({ node: n.id, member: null, label: n.label, sub: null, onFloor: true });
  }
  return out;
}

export const srcKey = (s) => `${s.node}:${s.member ?? "-"}`;
export const topicOf = (s, view) => `observer:${s.node}:${s.member ?? "-"}:${view}`;
const srcName = (s) => `${s.label}${s.member ? ` (${s.sub && s.sub !== s.member ? `${s.sub}, ` : ""}${s.member})` : s.sub ? ` (${s.sub})` : ""}`;

// ---- a set of feed subscriptions ----------------------------------------------

// sync([{topic, src}]) subscribes what is new and leaves what is gone; each
// topic keeps its last data, its error and a refusal, never one for another.
class FeedSet {
  constructor(onChange) {
    this.subs = new Map();
    this.onChange = onChange;
  }

  sync(list) {
    const want = new Map(list.map((x) => [x.topic, x]));
    for (const [t, s] of this.subs) if (!want.has(t)) { s.unsub(); this.subs.delete(t); }
    for (const [t, x] of want) {
      if (this.subs.has(t)) { this.subs.get(t).src = x.src; continue; }
      const s = { topic: t, src: x.src, at: null, data: null, error: null, refused: null, joined: false, prev: null, rps: new Map() };
      this.subs.set(t, s);
      s.unsub = bus.subscribe(t, (ev, p) => { if (ev === "feed") this.take(s, p); }, {
        onJoin: (p) => { s.joined = true; s.refused = null; if (p && p.at) this.take(s, p); else this.onChange(s); },
        onError: (reason) => { s.refused = reason; this.onChange(s); },
      });
    }
    this.onChange(null);
  }

  take(s, p) {
    if (p.at && p.at === s.at) return; // the join reply and the push of the same fetch
    if (p.data) {
      // reductions/s: the engine's own window for sort=reductions, else the
      // difference between this read and the last one of the same pid
      const d = p.data;
      s.rps = new Map();
      if (d.interval_ms > 0) for (const x of d.procs ?? []) s.rps.set(x.pid, x.reductions_per_s);
      else if (s.data && s.at) {
        const dt = (Date.parse(p.at) - Date.parse(s.at)) / 1000;
        const before = new Map((s.data.procs ?? []).map((x) => [x.pid, x.reductions]));
        if (dt > 0) for (const x of d.procs ?? []) if (before.has(x.pid)) s.rps.set(x.pid, Math.max(0, (x.reductions - before.get(x.pid)) / dt));
      }
      s.data = d; s.error = null;
    } else s.error = p.error ?? `feed answered neither data nor error: ${JSON.stringify(p).slice(0, 200)}`;
    s.at = p.at;
    this.onChange(s);
  }

  clear() { this.sync([]); }
  get list() { return [...this.subs.values()]; }
}

// ---- rows and the query --------------------------------------------------------

function toRow(s, p) {
  return {
    key: `${srcKey(s.src)}:${p.pid}`, src: s.src, node: s.src.node, member: s.src.member,
    pid: p.pid, name: p.registered_name ?? null, initial: p.initial_call ?? null, current: p.current_function ?? null,
    mq: p.message_queue_len, memory: p.memory, reductions: p.reductions,
    rps: s.rps.has(p.pid) ? s.rps.get(p.pid) : null, status: p.status, links: p.links,
    stale: !!s.error, at: s.at,
  };
}

const NUMERIC = { mq: "mq", mailbox: "mq", message_queue_len: "mq", memory: "memory", mem: "memory", reductions: "reductions", red: "reductions", rps: "rps", links: "links" };
const EXACT = { node: (r) => [r.node, r.src.label], member: (r) => [r.member ?? "-", r.src.sub ?? ""], pid: (r) => [r.pid], status: (r) => [r.status] };
const TEXT = { name: (r) => [r.name ?? r.initial ?? ""], fn: (r) => [r.current ?? ""], current: (r) => [r.current ?? ""], initial: (r) => [r.initial ?? ""], call: (r) => [r.initial ?? ""] };
const FIELDS = [...Object.keys(EXACT), ...Object.keys(TEXT), ...Object.keys(NUMERIC)];

const globRe = (v, whole) => new RegExp(`${whole ? "^" : ""}${v.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}${whole ? "$" : ""}`, "i");

// "1MB" is 1024², "2k" is 2000; a bare number is itself
function amount(s) {
  const m = /^(-?\d+(?:\.\d+)?)\s*([kmgt]?)(i?b)?$/i.exec(s);
  if (!m) return null;
  const k = m[2].toLowerCase();
  const pow = { "": 0, k: 1, m: 2, g: 3, t: 4 }[k];
  return +m[1] * (m[3] ? 1024 : 1000) ** pow;
}

function valueTest(key, val, kind) {
  if (kind === "regex") {
    let re;
    try { re = new RegExp(val, "i"); } catch (x) { return { error: `bad regex /${val}/: ${x.message}` }; }
    return { fn: (xs) => xs.some((x) => re.test(x)) };
  }
  if (NUMERIC[key]) {
    const m = /^(>=|<=|>|<|=)?(.+)$/.exec(val);
    const n = m && amount(m[2]);
    if (n == null) return { error: `${key}:${val} is not a number (try ${key}:>100, ${key}:>1MB, ${key}:>2k)` };
    const op = m[1] || "=";
    return { fn: (x) => x != null && (op === ">" ? x > n : op === "<" ? x < n : op === ">=" ? x >= n : op === "<=" ? x <= n : x === n) };
  }
  const exact = !!EXACT[key];
  if (val.includes("*")) { const re = globRe(val, exact); return { fn: (xs) => xs.some((x) => re.test(x)) }; }
  const lo = val.toLowerCase();
  return { fn: exact ? (xs) => xs.some((x) => x.toLowerCase() === lo) : (xs) => xs.some((x) => x.toLowerCase().includes(lo)) };
}

// -> {test(row) -> bool, error}; an unknown field is an error, not a miss
export function compile(q) {
  const { clauses, error } = parse(q || "");
  if (error) return { test: () => true, error };
  let err = null;
  const one = (c) => {
    if (c.or) { const parts = c.or.map(one); return (r) => parts.some((f) => f(r)); }
    const key = c.key ? c.key.toLowerCase() : null;
    if (key && !FIELDS.includes(key)) { err ??= `no field "${c.key}": one of ${FIELDS.join(", ")}`; return () => true; }
    const vals = c.any ?? [{ val: c.val, kind: c.kind }];
    const tests = vals.map((v) => valueTest(key, v.val, v.kind));
    const bad = tests.find((t) => t.error);
    if (bad) { err ??= bad.error; return () => true; }
    let f;
    if (!key) f = (r) => tests.some((t) => t.fn(haystack(r)));
    else if (NUMERIC[key]) f = (r) => tests.some((t) => t.fn(r[NUMERIC[key]]));
    else {
      const get = EXACT[key] ?? TEXT[key];
      f = (r) => tests.some((t) => t.fn(get(r)));
    }
    return c.neg ? (r) => !f(r) : f;
  };
  const fns = clauses.map(one);
  return { test: (r) => fns.every((f) => f(r)), error: err };
}

const haystack = (r) => [r.node, r.src.label, r.member ?? "", r.pid, r.name ?? "", r.initial ?? "", r.current ?? "", r.status ?? ""];

// ---- columns -----------------------------------------------------------------

const COLS = [
  { id: "src", label: "node / member", get: (r) => srcName(r.src), num: false },
  { id: "pid", label: "pid", get: (r) => r.pid.split(".").map((x) => x.padStart(8, "0")).join("."), num: false },
  { id: "name", label: "name or initial call", get: (r) => r.name ?? r.initial ?? "", num: false },
  { id: "current", label: "current function", get: (r) => r.current ?? "", num: false },
  { id: "mq", label: "mailbox", get: (r) => r.mq, num: true, metric: "message_queue_len" },
  { id: "memory", label: "memory", get: (r) => r.memory, num: true, metric: "memory" },
  { id: "rps", label: "reductions/s", get: (r) => r.rps, num: true, metric: "reductions" },
  { id: "status", label: "status", get: (r) => r.status ?? "", num: false },
];

// Recently seen processes, for the jump list: newest first.
const recent = new Map();
function remember(rows) {
  const now = Date.now();
  for (const r of rows) { recent.delete(r.key); recent.set(r.key, { ...r, seen: now }); }
  while (recent.size > RECENT_MAX) recent.delete(recent.keys().next().value);
}

// ---- the panel ---------------------------------------------------------------

export class Processes {
  // api: outer() the floor, go(id, member) -> null | why not, onOpen(), lens
  // (main.js lens owner), redraw()
  constructor(api) {
    this.api = api;
    this.scope = store.get(SCOPE_KEY) || "all";
    this.sortBy = "memory"; // the feed: which top 50 each source sends
    this.col = "memory"; this.dir = -1;
    this.query = "";
    this.compiled = compile("");
    this.selected = null; // row key
    this.detail = null; // {src, pid, topic, unsub, at, data, error, refused, result, busy}
    this.actions = [];
    this.note = null;
    this.feeds = new FeedSet(() => this.schedule());
    this.lensCtl = new ProcLens({ outer: api.outer, lens: api.lens, onChange: () => this.renderLens() });
    this.unsubSnap = null;
    this.unsubActions = null;
    this.raf = 0;

    this.btn = $("procsbtn");
    this.el = document.createElement("aside");
    this.el.id = "procs";
    this.el.hidden = true;
    this.el.setAttribute("aria-label", "Processes on every BEAM on the floor");
    this.el.innerHTML = `
      <div class="pr-head">
        <h3>Processes <span class="unk pr-sum"></span></h3>
        <button class="iconbtn" data-close aria-label="Close">×</button>
      </div>
      <div class="pr-bar">
        <label class="pr-scope">Scope <select aria-label="Scope"></select></label>
        <label class="pr-sortsel">Top 50 by <select aria-label="Which top 50 each BEAM sends">
          <option value="memory">memory</option><option value="message_queue_len">mailbox</option><option value="reductions">reductions/s</option></select></label>
        <span class="pr-lens">
          <button type="button" class="pr-lensbtn" aria-pressed="false">Metric lens</button>
          <select class="pr-lensm" aria-label="Lens metric">
            <option value="message_queue_len">mailbox</option><option value="memory">memory</option><option value="reductions">reductions/s</option></select>
        </span>
      </div>
      <p class="pr-lensnote unk" hidden></p>
      <div class="pr-search">
        <input type="search" spellcheck="false" autocomplete="off" aria-label="Search processes"
          placeholder="/  mq:>100 node:marginalia* -status:waiting memory:>1MB name:Runs">
      </div>
      <p class="pr-qerr" hidden></p>
      <div class="pr-sources"></div>
      <p class="pr-note" hidden></p>
      <div class="pr-main">
        <div class="pr-tablewrap"><table class="pr-table">
          <thead><tr>${COLS.map((c) => `<th data-col="${c.id}" class="${c.num ? "r" : ""} c-${c.id}" tabindex="0" aria-sort="none">${esc(c.label)}</th>`).join("")}<th class="c-go"></th></tr></thead>
          <tbody></tbody>
        </table><p class="pr-empty unk" hidden></p></div>
        <section class="pr-detail" hidden aria-label="Process"></section>
      </div>
      <details class="pr-actions"><summary>Actions on the floor <span class="unk">anyone's, as they happen</span> <b class="pr-actn"></b></summary><ol></ol></details>
      <p class="pr-keys unk">/ search · ↑↓ pick · Enter open · Esc back · ⌘K / Ctrl+K jump</p>`;
    document.body.appendChild(this.el);
    this.sumEl = this.el.querySelector(".pr-sum");
    this.scopeSel = this.el.querySelector(".pr-scope select");
    this.sortSel = this.el.querySelector(".pr-sortsel select");
    this.input = this.el.querySelector(".pr-search input");
    this.qerr = this.el.querySelector(".pr-qerr");
    this.srcEl = this.el.querySelector(".pr-sources");
    this.noteEl = this.el.querySelector(".pr-note");
    this.tbody = this.el.querySelector("tbody");
    this.emptyEl = this.el.querySelector(".pr-empty");
    this.detailEl = this.el.querySelector(".pr-detail");
    this.lensBtn = this.el.querySelector(".pr-lensbtn");
    this.lensSel = this.el.querySelector(".pr-lensm");
    this.lensNote = this.el.querySelector(".pr-lensnote");
    this.actEl = this.el.querySelector(".pr-actions ol");
    this.actN = this.el.querySelector(".pr-actn");

    this.modal = document.createElement("div");
    this.modal.id = "pr-modal";
    this.modal.hidden = true;
    document.body.appendChild(this.modal);
    this.toast = document.createElement("div");
    this.toast.id = "pr-toast";
    this.toast.hidden = true;
    document.body.appendChild(this.toast);

    this.btn?.addEventListener("click", () => this.toggle());
    $("procsbtn2")?.addEventListener("click", () => this.toggle(true));
    // Another panel opening closes this one (they share the left of the screen).
    for (const id of ["legendbtn", "sitesbtn", "buildbtn", "beambtn", "missionsbtn", "beambtn2", "tourbtn", "tourbtn2"]) {
      $(id)?.addEventListener("click", () => this.toggle(false));
    }
    this.el.querySelector("[data-close]").addEventListener("click", () => this.toggle(false));
    this.scopeSel.addEventListener("change", () => this.setScope(this.scopeSel.value));
    this.sortSel.addEventListener("change", () => this.setSort(this.sortSel.value, true));
    this.input.addEventListener("input", () => { this.query = this.input.value; this.compiled = compile(this.query); this.render(); });
    this.el.querySelector("thead").addEventListener("click", (e) => { const th = e.target.closest("th[data-col]"); if (th) this.sortCol(th.dataset.col); });
    this.el.querySelector("thead").addEventListener("keydown", (e) => { const th = e.target.closest("th[data-col]"); if (th && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); this.sortCol(th.dataset.col); } });
    this.tbody.addEventListener("click", (e) => {
      const tr = e.target.closest("tr[data-k]");
      if (!tr) return;
      const row = this.rowsByKey.get(tr.dataset.k);
      if (e.target.closest("[data-go]")) { this.go(row); return; }
      this.selected = tr.dataset.k; this.openDetail(row); this.render();
    });
    this.detailEl.addEventListener("click", (e) => this.onDetailClick(e));
    this.lensBtn.addEventListener("click", () => this.lensCtl.set(!this.lensCtl.on));
    this.lensSel.addEventListener("change", () => this.lensCtl.setMetric(this.lensSel.value));
    this.modal.addEventListener("click", (e) => { if (e.target === this.modal) this.closeModal(); });
    document.addEventListener("keydown", (e) => this.key(e), true);
    this.rowsByKey = new Map();
    this.rows = [];
  }

  get open() { return !this.el.hidden; }
  recent() { return [...recent.values()].reverse(); }

  toggle(open) {
    const want = open ?? this.el.hidden;
    if (want === this.open) return;
    this.el.hidden = !want;
    this.btn?.setAttribute("aria-expanded", String(want));
    document.body.classList.toggle("procs-open", want);
    if (want) {
      this.api.onOpen?.();
      this.unsubSnap = bus.subscribe("snapshots", (ev) => { if (ev === "snapshot") this.resync(); }, { onJoin: () => this.resync() });
      this.unsubActions = bus.subscribe("actions", (ev, a) => { if (ev === "action") this.takeAction(a); });
      // the socket's state: while it is not connected nothing here is live
      this.unsubState = bus.onState((st) => { this.link = st; this.render(); });
      this.resync();
    } else {
      // leave every feed this panel watched
      this.feeds.clear();
      this.closeDetail();
      this.unsubSnap?.(); this.unsubSnap = null;
      this.unsubActions?.(); this.unsubActions = null;
      this.unsubState?.(); this.unsubState = null;
      this.closeModal();
    }
    this.api.redraw?.();
  }

  // ---- scope and sources ---------------------------------------------------------

  sources() {
    const rep = reportingSources(this.api.outer());
    if (this.scope === "observer") return [observerSource()];
    if (this.scope === "all") return rep;
    return rep.filter((s) => s.node === this.scope);
  }

  setScope(scope) {
    this.scope = scope;
    store.set(SCOPE_KEY, scope);
    this.selected = null;
    this.resync();
  }

  setSort(metric, fromSelect = false) {
    this.sortBy = metric;
    this.sortSel.value = metric;
    if (fromSelect) { this.col = COLS.find((c) => c.metric === metric).id; this.dir = -1; }
    this.resync();
  }

  sortCol(id) {
    const c = COLS.find((x) => x.id === id);
    if (this.col === id) this.dir = -this.dir;
    else { this.col = id; this.dir = c.num ? -1 : 1; }
    // a metric column also asks every source for its top 50 by that metric
    if (c.metric && c.metric !== this.sortBy) this.setSort(c.metric);
    else this.render();
  }

  resync() {
    if (!this.open) return;
    this.renderScope();
    const srcs = this.sources();
    this.feeds.sync(srcs.map((s) => ({ topic: topicOf(s, `procs:${this.sortBy}`), src: s })));
  }

  renderScope() {
    const rep = reportingSources(this.api.outer());
    const bldgs = [...new Map(rep.map((s) => [s.node, s])).values()];
    if (this.scope !== "all" && this.scope !== "observer" && !bldgs.some((b) => b.node === this.scope)) {
      // the building stopped reporting or left the floor: say so in the list
      bldgs.push({ node: this.scope, label: `${this.scope} (not reporting now)`, gone: true });
    }
    const opts = [
      `<option value="all">All reporting buildings (${rep.length} BEAM${rep.length === 1 ? "" : "s"})</option>`,
      `<option value="observer">The observer (this VM)</option>`,
      ...bldgs.map((b) => {
        const n = rep.filter((s) => s.node === b.node).length;
        return `<option value="${esc(b.node)}">${esc(b.label)}${n > 1 ? ` — ${n} members` : ""}</option>`;
      }),
    ].join("");
    if (this.scopeSel.dataset.opts !== opts) { this.scopeSel.innerHTML = opts; this.scopeSel.dataset.opts = opts; }
    this.scopeSel.value = this.scope;
  }

  // ---- rendering -----------------------------------------------------------------

  schedule() {
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => { this.raf = 0; this.render(); });
  }

  render() {
    if (!this.open) return;
    const subs = this.feeds.list;
    const all = [];
    for (const s of subs) if (s.data) for (const p of s.data.procs ?? []) all.push(toRow(s, p));
    remember(all);
    this.rowsByKey = new Map(all.map((r) => [r.key, r]));
    this.qerr.hidden = !this.compiled.error;
    this.qerr.textContent = this.compiled.error ? `Search: ${this.compiled.error}` : "";
    const col = COLS.find((c) => c.id === this.col);
    const rows = all.filter(this.compiled.test).sort((a, b) => {
      const x = col.get(a), y = col.get(b);
      if (col.num) { if (x == null && y == null) return 0; if (x == null) return 1; if (y == null) return -1; return (x - y) * this.dir; }
      return String(x).localeCompare(String(y)) * this.dir;
    });
    this.rows = rows;

    // the source strip: every source, how it is doing
    const down = this.notLive();
    this.srcEl.innerHTML = subs.length ? subs.map((s) => {
      const name = esc(srcName(s.src));
      if (down) return `<div class="pr-src bad"><b>${name}</b> not live: ${esc(down)}${s.data ? ` <span class="unk">— rows below are from ${esc(timeOf(s.data, s))}</span>` : ""}</div>`;
      if (s.refused) return `<div class="pr-src bad"><b>${name}</b> refused: ${esc(s.refused)}</div>`;
      if (s.error) return `<div class="pr-src bad"><b>${name}</b> ${esc(s.error)}${s.data ? ` <span class="unk">— rows below are from ${esc(timeOf(s.data, s))}</span>` : ""}</div>`;
      if (!s.data) return `<div class="pr-src wait"><b>${name}</b> <span class="unk">waiting for the first read…</span></div>`;
      const d = s.data;
      return `<div class="pr-src ok"><b>${name}</b> <span class="unk">${esc(d.node)} · top ${(d.procs ?? []).length} of ${num(d.total)} by ${esc(METRICS[d.sort]?.label ?? d.sort)}${d.walked < d.total ? `, walked ${num(d.walked)}` : ""} · ${esc(d.took_ms)} ms</span></div>`;
    }).join("") : `<div class="pr-src bad">${this.scope === "all" ? "No building on the floor reports its inside, so there is no BEAM to read. Try the observer." : "Nothing to read in this scope."}</div>`;

    const live = down ? 0 : subs.filter((s) => s.data && !s.error).length;
    this.sumEl.textContent = `${rows.length} of ${all.length} shown · ${live} of ${subs.length} source${subs.length === 1 ? "" : "s"} live${down ? ` (not live: ${down})` : ""}`;

    for (const th of this.el.querySelectorAll("th[data-col]")) {
      const on = th.dataset.col === this.col;
      th.setAttribute("aria-sort", on ? (this.dir > 0 ? "ascending" : "descending") : "none");
      th.classList.toggle("on", on);
      th.classList.toggle("feed", COLS.find((c) => c.id === th.dataset.col).metric === this.sortBy);
    }
    if (this.selected && !this.rowsByKey.has(this.selected) && !this.detail) this.selected = null;
    const shown = rows.slice(0, ROWS_MAX);
    this.drawRows(shown);
    this.emptyEl.hidden = shown.length > 0;
    this.emptyEl.textContent = all.length ? `No process matches “${this.query}”.` : subs.some((s) => s.data) ? "No processes." : "";
    if (rows.length > ROWS_MAX) this.emptyEl.hidden = false, this.emptyEl.textContent = `${rows.length - ROWS_MAX} more not drawn: narrow the search.`;
    this.renderDetail();
  }

  // Rows are kept by key and replaced only when they change: a feed push
  // every 2 s per source must not swap the row out from under a click.
  drawRows(shown) {
    const old = this.rowEls ?? new Map();
    const next = new Map();
    const tpl = document.createElement("tbody");
    let i = 0;
    for (const r of shown) {
      const html = this.rowHtml(r);
      let el = old.get(r.key);
      if (!el) { tpl.innerHTML = html; el = tpl.firstElementChild; el.__html = html; }
      else if (el.__html !== html) {
        // patch cell by cell, so the row and its cells stay the elements under the pointer
        tpl.innerHTML = html;
        const fresh = tpl.firstElementChild;
        el.className = fresh.className;
        [...fresh.children].forEach((td, j) => {
          const cur = el.children[j];
          if (cur.innerHTML !== td.innerHTML) cur.innerHTML = td.innerHTML;
          if (cur.className !== td.className) cur.className = td.className;
          if (cur.title !== td.title) cur.title = td.title;
        });
        el.__html = html;
      }
      next.set(r.key, el);
      if (this.tbody.children[i] !== el) this.tbody.insertBefore(el, this.tbody.children[i] ?? null);
      i++;
    }
    while (this.tbody.children.length > i) this.tbody.lastElementChild.remove();
    this.rowEls = next;
  }

  rowHtml(r) {
    const name = r.name ? `<b>${esc(r.name)}</b>` : `<span class="unk">${esc(r.initial ?? "-")}</span>`;
    const lvl = (m, v) => (v == null ? "" : v >= METRICS[m].alert ? " alert" : v >= METRICS[m].warn ? " warn" : "");
    const rps = r.rps == null ? `<span class="unk" title="needs two reads of this process">-</span>` : num(r.rps);
    const go = r.src.onFloor ? `<button type="button" class="pr-go" data-go title="Fly to ${esc(srcName(r.src))}" aria-label="Fly to the building">↗</button>` : "";
    return `<tr data-k="${esc(r.key)}" class="${r.key === this.selected ? "sel" : ""}${r.stale ? " stale" : ""}">
      <td class="c-src" title="${esc(srcName(r.src))}">${r.src.member ? `<b class="mono">${esc(r.src.member.split(".").slice(-2).join("."))}</b> ` : ""}${esc(r.src.label)}</td>
      <td class="c-pid mono">${esc(r.pid)}</td>
      <td class="c-name">${name}</td>
      <td class="c-current mono">${esc(r.current ?? "-")}</td>
      <td class="c-mq r mono${lvl("message_queue_len", r.mq)}">${num(r.mq)}</td>
      <td class="c-memory r mono${lvl("memory", r.memory)}">${bytes(r.memory)}</td>
      <td class="c-rps r mono${lvl("reductions", r.rps)}" title="${esc(num(r.reductions))} reductions since it started">${rps}</td>
      <td class="c-status st-${esc(r.status)}">${esc(r.status ?? "-")}</td>
      <td class="c-go">${go}</td></tr>`;
  }

  renderLens() {
    const l = this.lensCtl;
    this.lensBtn.setAttribute("aria-pressed", String(l.on));
    this.lensBtn.classList.toggle("on", l.on);
    this.lensSel.value = l.metric;
    this.lensNote.hidden = !l.on;
    this.lensNote.innerHTML = l.on ? l.noteHtml() : "";
  }

  // ---- keys ----------------------------------------------------------------------

  key(e) {
    if (!this.open || (e.metaKey || e.ctrlKey || e.altKey)) return;
    if (!this.modal.hidden) {
      if (e.key === "Escape") { e.stopPropagation(); e.preventDefault(); this.closeModal(); }
      return;
    }
    if (document.getElementById("jump") && !document.getElementById("jump").hidden) return;
    const inInput = e.target === this.input;
    if (e.key === "Escape") {
      e.stopPropagation(); e.preventDefault();
      if (inInput && this.input.value) { this.input.value = ""; this.query = ""; this.compiled = compile(""); this.render(); return; }
      if (inInput) { this.input.blur(); return; }
      if (this.detail) { this.closeDetail(); this.render(); return; }
      this.toggle(false);
      return;
    }
    if (typing(e.target) && !inInput) return;
    if (e.key === "/" && !inInput) { e.preventDefault(); e.stopPropagation(); this.input.focus(); this.input.select(); return; }
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      if (!this.rows.length) return;
      e.preventDefault(); e.stopPropagation();
      // picking rows takes the keys from a header or button, so Enter opens the row
      if (!inInput && document.activeElement?.closest?.("#procs th, #procs button")) document.activeElement.blur();
      let i = this.rows.findIndex((r) => r.key === this.selected);
      i = i < 0 ? 0 : Math.max(0, Math.min(this.rows.length - 1, i + (e.key === "ArrowDown" ? 1 : -1)));
      this.selected = this.rows[i].key;
      this.render();
      this.tbody.querySelector(`tr[data-k="${CSS.escape(this.selected)}"]`)?.scrollIntoView({ block: "nearest" });
      return;
    }
    if (e.key === "Enter" && this.selected && (inInput || !typing(e.target)) && !e.target.closest("button, summary, th")) {
      const row = this.rowsByKey.get(this.selected);
      if (row) { e.preventDefault(); e.stopPropagation(); this.openDetail(row); }
    }
  }

  // ---- fly to a building ---------------------------------------------------------

  go(row) {
    const s = row.src;
    if (!s.onFloor) { this.say(`${srcName(s)} is the observer's own VM, not a building on the floor.`); return; }
    const why = this.api.go(s.node, s.member);
    if (why) { this.say(`Fly to ${srcName(s)}: ${why}`, true); return; }
    this.say(s.member
      ? `${s.label} is a cluster: ${row.pid}${row.name ? ` (${row.name})` : ""} runs on member ${s.sub && s.sub !== s.member ? `${s.sub} at ` : ""}${s.member}. Open the building to see that member's machine room.`
      : `Flew to ${s.label}: ${row.pid}${row.name ? ` (${row.name})` : ""} runs there.`);
  }

  say(text, bad = false) {
    this.noteEl.textContent = text;
    this.noteEl.classList.toggle("bad", bad);
    this.noteEl.hidden = false;
    // the panel may have been closed on a phone: the toast says it there
    this.toast.textContent = text;
    this.toast.classList.toggle("bad", bad);
    this.toast.hidden = this.open && window.innerWidth >= 760;
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => { this.toast.hidden = true; }, 7000);
  }

  // ---- the detail pane -----------------------------------------------------------

  // From the jump list: show this process, in a scope that has its source.
  openProc(row) {
    this.toggle(true);
    const s = row.src;
    const scope = s.node === OBSERVER ? "observer" : this.scope === "all" ? "all" : s.node;
    if (scope !== this.scope) this.setScope(scope);
    this.selected = row.key;
    this.openDetail(row);
  }

  openDetail(row) {
    if (!row) return;
    const topic = topicOf(row.src, `proc:${row.pid}`);
    if (this.detail?.topic === topic) { this.renderDetail(); return; }
    this.closeDetail();
    const d = { src: row.src, pid: row.pid, row, topic, at: null, data: null, error: null, refused: null, result: null, busy: null };
    this.detail = d;
    this.el.classList.add("detailing");
    d.unsub = bus.subscribe(topic, (ev, p) => { if (ev === "feed") this.takeDetail(d, p); }, {
      onJoin: (p) => { d.refused = null; if (p && p.at) this.takeDetail(d, p); else this.renderDetail(); },
      onError: (reason) => { d.refused = reason; this.renderDetail(); },
    });
    this.renderDetail();
  }

  takeDetail(d, p) {
    if (d !== this.detail) return;
    if (p.data) { d.data = p.data; d.error = null; } else d.error = p.error;
    d.at = p.at;
    this.renderDetail();
  }

  closeDetail() {
    if (!this.detail) return;
    this.detail.unsub?.();
    this.detail = null;
    this.el.classList.remove("detailing");
    this.detailEl.hidden = true;
    this.detailEl.innerHTML = "";
  }

  // null while the socket is connected, else what it is doing, e.g. "reconnecting: websocket closed"
  notLive() {
    const st = this.link ?? bus.state();
    return st.state === "connected" ? null : `${st.state}${st.detail ? `: ${st.detail}` : ""}`;
  }

  renderDetail() {
    const d = this.detail;
    if (!d) { this.detailEl.hidden = true; return; }
    const down = this.notLive();
    this.detailEl.hidden = false;
    const p = d.data ?? null;
    const r = d.row;
    const kv = (k, v) => `<dt>${esc(k)}</dt><dd>${v}</dd>`;
    const list = (xs, n, f) => (xs?.length ? `${xs.slice(0, 12).map(f).join(", ")}${n > 12 ? ` <span class="unk">+${n - 12}</span>` : ""}` : `<span class="unk">none</span>`);
    const who = (x) => esc(x.pid ?? x.port ?? x.name ?? JSON.stringify(x));
    const state = down ? `<p class="pr-bad">Not live (${esc(down)}): actions are off until the socket is back${p ? ` <span class="unk">— below is as of ${esc(timeOf(p, d))}</span>` : ""}</p>`
      : d.refused ? `<p class="pr-bad">Refused: ${esc(d.refused)}</p>`
      : d.error ? `<p class="pr-bad">${esc(d.error)}${p ? ` <span class="unk">— below is as of ${esc(timeOf(p, d))}</span>` : ""}</p>`
      : !p ? `<p class="unk">Reading ${esc(d.pid)}…</p>` : "";
    const name = p?.registered_name ?? r?.name ?? null;
    const body = p ? `
      <dl class="pr-kv">
        ${kv("status", esc(p.status))}
        ${kv("mailbox", `<span class="mono">${num(p.message_queue_len)}</span>`)}
        ${kv("memory", `<span class="mono">${bytes(p.memory)}</span> <span class="unk">heap ${num(p.heap_size_words)} / total ${num(p.total_heap_size_words)} words, stack ${num(p.stack_size_words)}</span>`)}
        ${kv("reductions", `<span class="mono">${num(p.reductions)}</span>`)}
        ${kv("current", `<span class="mono">${esc(p.current_function ?? "-")}</span>`)}
        ${kv("initial call", `<span class="mono">${esc(p.initial_call ?? "-")}</span>`)}
        ${kv("application", esc(p.application ?? "-"))}
        ${kv("supervisors", p.supervisor_path?.length ? p.supervisor_path.map((x) => `<span class="mono">${esc(typeof x === "string" ? x : x.pid ?? JSON.stringify(x))}</span>`).join(" › ") : `<span class="unk">none known</span>`)}
        ${kv("links", list(p.links, p.links_count, who))}
        ${kv("monitors", list(p.monitors, p.monitors_count, who))}
        ${kv("monitored by", list(p.monitored_by, p.monitored_by_count, who))}
        ${kv("trap exit", esc(p.trap_exit))}
        ${kv("priority", esc(p.priority))}
        ${kv("group leader", `<span class="mono">${esc(p.group_leader ?? "-")}</span>`)}
        ${kv("gc", p.garbage_collection ? `<span class="mono">${esc(Object.entries(p.garbage_collection).map(([k, v]) => `${k} ${v}`).join(", "))}</span>` : "-")}
        ${kv("dictionary", p.dictionary_not_read ? `<span class="unk">not listed: ${esc(p.dictionary_not_read)}</span>` : p.dictionary_count ? `${num(p.dictionary_count)} keys: <span class="mono">${esc((p.dictionary_keys ?? []).join(", "))}</span>` : `<span class="unk">empty</span>`)}
      </dl>
      <h5>Stack</h5>
      <ol class="pr-stack mono">${(p.current_stacktrace ?? []).map((f) => `<li>${esc(f.mfa)} <span class="unk">${esc(f.file ?? "")}${f.line ? `:${f.line}` : ""}</span></li>`).join("") || "<li class=unk>empty</li>"}</ol>` : "";
    const res = d.result ? `<p class="${d.result.ok ? "pr-ok" : "pr-bad"}">${esc(d.result.text)}</p>` : "";
    const busy = !!d.busy || !!down;
    this.detailEl.innerHTML = `
      <div class="pr-dhead">
        <button type="button" class="pr-back" data-back aria-label="Back to the list">‹ list</button>
        <div><b class="mono">${esc(d.pid)}</b> ${name ? `<b>${esc(name)}</b>` : ""}<div class="unk">${esc(srcName(d.src))}${p ? ` · ${esc(p.node)} · as of ${esc(timeOf(p, d))}` : ""}</div></div>
        <button class="iconbtn" data-back aria-label="Close the process">×</button>
      </div>
      ${state}
      <div class="pr-dacts">
        <button type="button" data-act="gc"${busy ? " disabled" : ""}>GC</button>
        <button type="button" class="danger" data-act="exit"${busy ? " disabled" : ""}>Exit (shutdown)</button>
        <button type="button" class="danger" data-act="kill"${busy ? " disabled" : ""}>Kill</button>
        ${d.src.onFloor ? `<button type="button" data-fly>Fly to ${esc(d.src.label)}</button>` : ""}
      </div>
      ${d.busy ? `<p class="unk">${esc(d.busy)}…</p>` : res}
      ${body}`;
  }

  onDetailClick(e) {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.hasAttribute("data-back")) { this.closeDetail(); this.render(); return; }
    if (b.hasAttribute("data-fly")) { this.go(this.detail.row); return; }
    if (b.dataset.act) this.confirm(b.dataset.act);
  }

  // ---- actions ---------------------------------------------------------------------

  confirm(act) {
    const d = this.detail;
    if (!d || this.notLive()) return;
    const name = d.data?.registered_name ?? d.row?.name ?? d.data?.initial_call ?? d.row?.initial ?? "no registered name";
    const what = {
      gc: { title: "Garbage-collect", btn: "GC it", text: "Runs a full garbage collection in the process now. It keeps running; its memory may drop." },
      exit: { title: "Exit (shutdown)", btn: "Send exit(shutdown)", text: "Sends exit(pid, :shutdown). A process that traps exits gets it as a message and may stay; otherwise it stops, and its supervisor decides whether to start a new one." },
      kill: { title: "Kill", btn: "Kill it", text: "Sends exit(pid, :kill), which cannot be trapped: the process stops now, its links get :killed, and its supervisor decides whether to start a new one." },
    }[act];
    const who = store.get(WHO_KEY) || "";
    this.modal.innerHTML = `<form class="pr-confirm" data-act="${act}">
      <h3>${esc(what.title)} <span class="mono">${esc(d.pid)}</span></h3>
      <p><b>${esc(name)}</b> on <b>${esc(srcName(d.src))}</b>${d.data?.node ? ` <span class="unk">(${esc(d.data.node)})</span>` : ""}</p>
      <p class="unk">${esc(what.text)} Everyone with the page sees who did it, and the observer logs it.</p>
      <label>You are <input name="who" maxlength="60" required placeholder="your name" autocomplete="nickname" spellcheck="false" value="${esc(who)}"></label>
      <p class="pr-bad" hidden></p>
      <div class="pr-mbtns"><button type="submit" class="${act === "gc" ? "go" : "danger"}">${esc(what.btn)}</button><button type="button" data-cancel>Cancel</button></div>
    </form>`;
    this.modal.hidden = false;
    const f = this.modal.querySelector("form");
    (who ? f.querySelector("button[type=submit]") : f.elements.who).focus();
    f.querySelector("[data-cancel]").addEventListener("click", () => this.closeModal());
    f.addEventListener("submit", (e) => {
      e.preventDefault();
      const name = f.elements.who.value.trim().slice(0, 60);
      if (!name) return;
      store.set(WHO_KEY, name);
      this.closeModal();
      this.act(d, act, name);
    });
  }

  async act(d, act, who) {
    const path = `proc/${d.pid}/${act}`;
    const params = act === "exit" ? { reason: "shutdown" } : {};
    d.busy = `${act} ${d.pid}`; d.result = null;
    this.renderDetail();
    try {
      const r = await bus.push(d.topic, "action", { path, params, by: `${who} (processes)` });
      d.result = { ok: true, text: describe(act, r) };
    } catch (x) {
      d.result = { ok: false, text: `${act} ${d.pid} failed: ${x.message}` };
    }
    d.busy = null;
    if (d === this.detail) this.renderDetail();
  }

  takeAction(a) {
    this.actions.unshift(a);
    this.actions.length = Math.min(this.actions.length, 20);
    this.actN.textContent = String(this.actions.length);
    this.actEl.innerHTML = this.actions.map((x) => `<li class="${x.error ? "bad" : ""}"><time>${esc((x.at ?? "").slice(11, 19))}</time> <b>${esc(x.by ?? "nobody said")}</b> ${esc(x.path)} on ${esc(x.node)}${x.member ? ` (${esc(x.member)})` : ""}: ${esc(x.status)} ${esc(x.error ?? describe(x.path.split("/").pop(), x.result ?? {}))}</li>`).join("");
  }

  closeModal() { this.modal.hidden = true; this.modal.innerHTML = ""; }
}

function describe(act, r) {
  if (act === "gc") return `GC done: ${bytes(r.memory_before)} → ${bytes(r.memory_after)}`;
  if (act === "kill" || act === "exit") return `${act} sent: ${r.alive_after ? "still alive after it" : `gone${r.exit_reason ? `, ${r.exit_reason}` : ""}`}`;
  return r.ok ? "done" : JSON.stringify(r).slice(0, 200);
}

const timeOf = (d, s) => (s.at ? s.at.slice(11, 19) + " UTC" : "?");

// ---- the metric lens ---------------------------------------------------------------

// Colours each reporting building by its worst process on one metric:
// the top of procs:<metric> from every member. Through the page's lens
// owner, so it and the missions lens never fight over scene.focus.
export class ProcLens {
  constructor({ outer, lens, onChange }) {
    this.outer = outer; this.lens = lens; this.onChange = onChange;
    this.metric = METRICS[store.get(LENS_METRIC_KEY)] ? store.get(LENS_METRIC_KEY) : "message_queue_len";
    this.on = false;
    this.worst = new Map(); // node -> {v, src, proc}
    this.failing = [];
    this.feeds = new FeedSet(() => this.update());
    this.unsubSnap = null;
  }

  set(on) {
    if (on === this.on) return;
    this.on = on;
    if (on) {
      this.unsubSnap = bus.subscribe("snapshots", (ev) => { if (ev === "snapshot") this.resync(); }, { onJoin: () => this.resync() });
      this.resync();
    } else {
      this.feeds.clear();
      this.unsubSnap?.(); this.unsubSnap = null;
      this.lens?.drop("processes");
    }
    this.onChange?.();
  }

  setMetric(m) {
    this.metric = m;
    store.set(LENS_METRIC_KEY, m);
    if (this.on) { this.feeds.clear(); this.resync(); }
    this.onChange?.();
  }

  resync() {
    if (!this.on) return;
    this.feeds.sync(reportingSources(this.outer()).map((s) => ({ topic: topicOf(s, `procs:${this.metric}`), src: s })));
  }

  update() {
    if (!this.on) return;
    const M = METRICS[this.metric];
    const val = (p) => (this.metric === "reductions" ? p.reductions_per_s : p[this.metric]);
    this.worst = new Map();
    this.failing = [];
    const read = new Set();
    for (const s of this.feeds.list) {
      if (s.refused || s.error) this.failing.push({ src: s.src, why: s.refused ? `refused: ${s.refused}` : s.error });
      if (!s.data || s.error) continue;
      read.add(s.src.node);
      for (const p of s.data.procs ?? []) {
        const v = val(p);
        if (v == null) continue;
        const w = this.worst.get(s.src.node);
        if (!w || v > w.v) this.worst.set(s.src.node, { v, src: s.src, proc: p });
      }
    }
    const map = new Map();
    for (const [id, w] of this.worst) if (w.v >= M.warn) map.set(id, w.v >= M.alert ? "alert" : "warn");
    const n = new Set(this.feeds.list.map((s) => s.src.node)).size;
    this.lens?.claim("processes", {
      map,
      label: `Processes lens: worst ${M.label}`,
      detail: `${map.size} of ${n} reporting building${n === 1 ? "" : "s"} lit · ${thresholds(this.metric)}${this.failing.length ? ` · ${this.failing.length} source${this.failing.length === 1 ? "" : "s"} not read` : ""}`,
      onDrop: () => { this.on = false; this.feeds.clear(); this.unsubSnap?.(); this.unsubSnap = null; this.onChange?.(); },
    });
    this.onChange?.();
  }

  noteHtml() {
    const M = METRICS[this.metric];
    const rows = [...this.worst.values()].sort((a, b) => b.v - a.v).slice(0, 6)
      .map((w) => `<li><b>${esc(w.src.label)}</b>${w.src.member ? ` (${esc(w.src.member)})` : ""}: ${esc(M.fmt(w.v))} — ${esc(w.proc.registered_name ?? w.proc.initial_call ?? w.proc.pid)}</li>`).join("");
    const fail = this.failing.map((f) => `<li class="bad"><b>${esc(srcName(f.src))}</b>: ${esc(f.why)}</li>`).join("");
    const none = !this.feeds.list.length ? "<li>No building on the floor reports its inside: nothing to colour.</li>" : "";
    return `Lit by the worst process's ${esc(M.label)}: ${esc(thresholds(this.metric))}. Unlit: below amber, or not read.<ul>${rows}${fail}${none}</ul>`;
  }
}
