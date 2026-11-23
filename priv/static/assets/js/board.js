// The board: the live BEAM systems on the floor, read like a trading floor.
// Only the BEAMs and what they lean on: each app's nodes, their processes,
// schedulers, memory, mailboxes and distribution, the Repo, and the app's
// own Postgres database. Static sites, external services and the host's
// disk are on the floor, not here.
//
//   the index row   in the top bar: processes, run queue, BEAM memory,
//                   reductions, the biggest mailbox, distribution traffic,
//                   Repo queries, app database connections, errors logged;
//                   each with its move over 5 minutes, green when the move
//                   is good for the system and red when it is bad
//   the chyron      over the timeline: LIVE or REPLAY, the top story off
//                   the BEAM wire (ObsFactor.Wire), rotating, and the clock
//   the crawl       every BEAM node (★ for what it leads), every Repo,
//                   every app database, and the latest wire headlines
//   the monitor     (Board, key b) three tabs:
//                     Wire  every happening, newest first, filterable by app
//                           and severity; click one to replay its moment
//                     BEAM  one row per node: processes with a sparkline,
//                           run queue on schedulers, memory, binaries,
//                           reductions, biggest mailbox, distribution
//                     DB    each app's Repo stream and its Postgres database
//
// The numbers are the tape's (each frame's `beam:`, `repo:` and `pg:`
// metrics) and the wire is the tape's, so a replayed moment shows the
// board, the chyron and the crawl as they were then.

import * as bus from "./bus.js";
import { esc, num, bytes } from "./fmt.js";

const WINDOW = 15 * 60e3; // what the sparklines and moves look back over
const MOVE = 5 * 60e3; // a move is against this long ago
const STORY_MS = 10 * 60e3; // a wire item is the chyron's story for this long
const ROTATE_MS = 6000;
const pad = (n) => String(n).padStart(2, "0");
const hms = (ms) => { const d = new Date(ms); return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`; };
const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const typing = (el) => el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
function ago(ms) { const m = Math.round(ms / 60e3); return m < 1 ? `${Math.round(ms / 1000)}s` : m < 60 ? `${m}m` : m < 2880 ? `${Math.floor(m / 60)}h ${pad(m % 60)}m` : `${Math.floor(m / 1440)}d`; }
// "marginalia@172.18.0.12" -> "@.0.12": what tells one compose member from another
function shortNode(n) { const m = /^([^@]+)@(?:\d+\.\d+\.)?(\d+\.\d+)$/.exec(n ?? ""); return m ? `${m[1]}@.${m[2]}` : n ?? "?"; }
const shortName = (n) => String(n ?? "").replace(/^Elixir\./, "").replace(/^:/, "");
function up(s) { return !isNum(s) ? "–" : s >= 86400 ? `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h` : s >= 3600 ? `${Math.floor(s / 3600)}h ${pad(Math.floor((s % 3600) / 60))}m` : `${Math.floor(s / 60)}m`; }

// which way is good: +1 more is good, -1 more is bad, 0 neither
const GOOD = { procs: 0, rq: -1, mem: -1, bin: -1, reds: 0, mbox: -1, dist_out: 0, sendq: -1, rate: 0, ms: -1, conns: -1, commits: 0, errors: -1 };
const FMT = {
  procs: (v) => num(v), rq: (v) => num(v), mem: bytes, bin: bytes, reds: (v) => `${num(v)}/s`, mbox: (v) => num(v),
  dist_out: (v) => `${bytes(v)}/s`, sendq: bytes, rate: (v) => `${num(v)}/s`, ms: (v) => `${num(v)} ms`, conns: (v) => num(v),
  commits: (v) => `${num(v)}/s`, errors: (v) => num(v), util: (v) => `${Math.round(v * 100)}%`, atoms: (v) => num(v),
};
const SEV_RANK = { alert: 0, warn: 1, info: 2 };
const EMPTY = () => ({ apps: [], sevs: [], kinds: [], q: "" });
const store = { get: (k) => { try { return localStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch {} } };
const AIR_KEY = "obs.wire.onair";

// does a wire item pass a filter spec (ObsFactor.WireFilters)? an empty
// part passes everything
export function matches(spec, w) {
  if (!spec) return true;
  if (spec.apps?.length && !spec.apps.includes(w.app)) return false;
  if (spec.sevs?.length && !spec.sevs.includes(w.sev)) return false;
  if (spec.kinds?.length && !spec.kinds.includes(w.kind)) return false;
  const q = (spec.q ?? "").trim().toLowerCase();
  if (q && !`${w.head} ${w.text ?? ""} ${w.member ?? ""} ${w.label ?? ""}`.toLowerCase().includes(q)) return false;
  return true;
}
const sameSpec = (a, b) => JSON.stringify(norm(a)) === JSON.stringify(norm(b));
const norm = (s) => ({ apps: [...(s?.apps ?? [])].sort(), sevs: [...(s?.sevs ?? [])].sort(), kinds: [...(s?.kinds ?? [])].sort(), q: (s?.q ?? "").trim() });

export class Board {
  constructor(api) {
    this.api = api; // { timeline, go(id), closeOthers(), onToggle() }
    this.series = []; // [[at, {key: {...}}]], oldest first
    this.wire = []; // wire items, newest first
    this.shown = null; this.shownAt = null;
    this.story = 0;
    this.tab = "wire";
    this.filter = EMPTY(); // the Wire tab's filter
    this.sets = []; // saved filter sets, shared (ObsFactor.WireFilters)
    this.setId = null; // the saved set the filter was loaded from
    this.air = store.get(AIR_KEY); // the set on air: the chyron and crawl follow it (this viewer only)
    this.el = document.getElementById("board");
    this.btn = document.getElementById("boardbtn");
    this.index = document.getElementById("indexrow");
    this.news = document.getElementById("news");
    this.news.innerHTML = `<div class="nw-chyron"><span class="nw-bug">LIVE</span><span class="nw-tag">BEAM</span><span class="nw-head"></span><span class="nw-clock"></span></div><div class="nw-crawl"><div class="nw-track"></div></div>`;
    this.btn.textContent = "Board";
    this.btn.addEventListener("click", () => this.toggle());
    this.el.addEventListener("click", (e) => this.onClick(e));
    this.el.addEventListener("input", (e) => {
      if (e.target.name !== "wq") return;
      this.filter.q = e.target.value;
      this.renderWireList(); // 500 items at most: no need to wait for a pause
    });
    this.el.addEventListener("submit", (e) => { e.preventDefault(); this.saveSet(e.target); });
    this.news.addEventListener("click", (e) => {
      const w = e.target.closest("[data-wire]");
      if (w) return this.openItem(this.wire.find((x) => String(x.id ?? x.key) === w.dataset.wire));
      const s = e.target.closest("[data-node]");
      if (s) this.api.go(s.dataset.node);
    });
    document.addEventListener("keydown", (e) => {
      if (e.key !== "b" || e.metaKey || e.ctrlKey || e.altKey || typing(e.target) || e.defaultPrevented) return;
      e.preventDefault(); this.toggle();
    });
    setInterval(() => { this.story++; this.renderChyron(); }, ROTATE_MS);
    setInterval(() => this.renderClock(), 1000);
    bus.subscribe("tape", (ev, t) => {
      if (ev === "tick") this.onTick(t);
      else if (ev === "filters") this.setSets(t.filters);
    }, {
      onJoin: (r) => {
        if (r.error) return;
        this.setSets(r.filters ?? []);
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

  onClick(e) {
    if (e.target.closest("[data-a=close]")) return this.toggle(false);
    const tab = e.target.closest("[data-tab]");
    if (tab) { this.tab = tab.dataset.tab; return this.renderMonitor(); }
    const f = e.target.closest("[data-f]");
    if (f) {
      const i = f.dataset.f.indexOf(":"), k = f.dataset.f.slice(0, i), v = f.dataset.f.slice(i + 1);
      if (k === "all") this.filter = EMPTY();
      else { const l = this.filter[k]; this.filter[k] = l.includes(v) ? l.filter((x) => x !== v) : [...l, v]; }
      return this.renderMonitor();
    }
    const set = e.target.closest("[data-set]");
    if (set) {
      const s = this.sets.find((x) => String(x.id) === set.dataset.set);
      const act = e.target.closest("[data-sa]")?.dataset.sa;
      if (!s) return;
      if (act === "air") { this.air = this.air === String(s.id) ? null : String(s.id); store.set(AIR_KEY, this.air); this.render(); return; }
      if (act === "del") { if (window.confirm(`Delete the filter set “${s.name}” for everyone?`)) bus.push("tape", "delete_filter", { id: s.id }).catch((x) => window.alert(x.message)); return; }
      // a click on the set itself loads it; again, clears it
      if (this.setId === s.id && sameSpec(this.filter, s.spec)) { this.setId = null; this.filter = EMPTY(); }
      else { this.setId = s.id; this.filter = { ...EMPTY(), ...structuredClone(s.spec) }; }
      return this.renderMonitor();
    }
    const sa = e.target.closest("[data-sa]");
    if (sa?.dataset.sa === "saveas") { this.naming = true; this.renderMonitor(); this.el.querySelector("form[data-form=set] input")?.focus(); return; }
    if (sa?.dataset.sa === "update") { const cur = this.sets.find((x) => x.id === this.setId); if (cur) bus.push("tape", "save_filter", { id: cur.id, name: cur.name, spec: this.filter }).catch((x) => window.alert(x.message)); return; }
    if (sa?.dataset.sa === "cancel") { this.naming = false; return this.renderMonitor(); }
    const w = e.target.closest("[data-wire]");
    if (w) return this.openItem(this.wire.find((x) => String(x.id ?? x.key) === w.dataset.wire));
    const r = e.target.closest("[data-node]");
    if (r) this.api.go(r.dataset.node);
  }

  setSets(list) {
    this.sets = list;
    if (this.air && !list.some((s) => String(s.id) === this.air)) { this.air = null; store.set(AIR_KEY, null); }
    if (this.setId && !list.some((s) => s.id === this.setId)) this.setId = null;
    this.render();
    if (this.open) this.renderMonitor(true);
  }

  saveSet(form) {
    if (form.dataset.form !== "set") return;
    const name = form.querySelector("input[name=name]").value;
    bus.push("tape", "save_filter", { name, spec: this.filter, by: this.api.who?.() || null })
      .then((r) => { this.naming = false; this.setId = r.filter.id; this.renderMonitor(); })
      .catch((x) => window.alert(x.message));
  }

  // the set on air: what the chyron and the crawl show of the wire
  airSet() { return this.air ? this.sets.find((s) => String(s.id) === this.air) ?? null : null; }
  aired() { const s = this.airSet(); return s ? this.wireUpTo().filter((w) => matches(s.spec, w)) : this.wireUpTo(); }

  // a wire item: replay its moment (5 s before), and go to its app
  openItem(it) {
    if (!it) return;
    this.api.timeline.play(false);
    this.api.timeline.seek(it.at - 5000);
    if (it.app) this.api.go(it.app);
  }

  // ---- the numbers and the wire -----------------------------------------------

  fetch(end) {
    this.fetching = end;
    const from = Math.round(end - WINDOW), to = Math.round(end);
    Promise.all([
      bus.push("tape", "series", { from, to, points: 180 }),
      bus.push("tape", "wire", { from: Math.round(end - 6 * 3600e3), to: to + 1000 }),
    ])
      .then(([s, w]) => {
        if (this.fetching !== end) return;
        this.series = s.series;
        this.wire = w.wire;
        this.fetchedEnd = end;
        this.render();
      })
      .catch((e) => console.error(`obs_factor board: ${e.message}`));
  }

  onTick(t) {
    if (this.api.timeline.replaying) return;
    if (t.metrics) {
      this.series.push([t.at, t.metrics]);
      while (this.series.length && this.series[0][0] < t.at - WINDOW) this.series.shift();
    }
    if (t.wire?.length) {
      // live items have no id until read back: key them by time and order
      const fresh = t.wire.map((w, i) => ({ ...w, key: `${t.at}-${i}` })).reverse();
      this.wire = [...fresh, ...this.wire].slice(0, 500);
      this.story = 0; // the newest story leads
      this.renderChyron();
      if (this.open && this.tab === "wire") this.renderMonitor(false);
    }
  }

  // what is on screen changed: the board follows it
  onShown(snap, at) {
    this.shown = snap; this.shownAt = at;
    if (this.api.timeline.replaying && (this.fetchedEnd == null || Math.abs(at - this.fetchedEnd) > 15_000) && !this.wait) {
      this.wait = setTimeout(() => { this.wait = null; this.fetch(this.shownAt); }, this.api.timeline.playing ? 400 : 0);
    } else if (!this.api.timeline.replaying && this.wasReplaying) {
      this.fetch(Date.now()); // back to live: the live window again
    }
    this.wasReplaying = this.api.timeline.replaying;
    this.render();
  }

  upTo() {
    const end = this.shownAt ?? Infinity;
    return this.series.filter((p) => p[0] <= end + 2500);
  }

  wireUpTo() {
    const end = (this.shownAt ?? Date.now()) + 2500;
    return this.wire.filter((w) => w.at <= end);
  }

  // the keys of one kind ("beam:", "repo:", "pg:") in the latest point
  keys(prefix) {
    const pts = this.upTo();
    const last = pts[pts.length - 1]?.[1] ?? {};
    return Object.keys(last).filter((k) => k.startsWith(prefix)).sort();
  }

  latest(key) { const pts = this.upTo(); return pts[pts.length - 1]?.[1]?.[key] ?? null; }

  // [now, then]: then is the value about MOVE ago
  move(key, field) {
    const pts = this.upTo();
    let now = null;
    for (let i = pts.length - 1; i >= 0; i--) { const v = pts[i][1][key]?.[field]; if (isNum(v)) { now = v; break; } }
    if (now == null) return [null, null];
    const target = pts[pts.length - 1][0] - MOVE;
    for (const p of pts) if (p[0] >= target) { const v = p[1][key]?.[field]; if (isNum(v)) return [now, v]; }
    return [now, null];
  }

  // a sum (or max) over many keys, now and MOVE ago
  agg(keys, field, max = false) {
    let n = null, t = null;
    for (const k of keys) {
      const [a, b] = this.move(k, field);
      if (a != null) n = n == null ? a : max ? Math.max(n, a) : n + a;
      if (b != null) t = t == null ? b : max ? Math.max(t, b) : t + b;
    }
    return [n, t];
  }

  delta(field, now, then) {
    if (now == null || then == null) return `<i class="bd-d flat">·</i>`;
    const d = now - then;
    const rel = then !== 0 ? d / Math.abs(then) : now !== 0 ? 1 : 0;
    if (Math.abs(rel) < 0.02) return `<i class="bd-d flat">▬</i>`;
    const good = GOOD[field] ?? 0;
    const cls = good === 0 ? "neu" : (d > 0) === (good > 0) ? "up" : "dn";
    const pct = then !== 0 ? `${Math.abs(rel * 100) >= 100 ? Math.round(Math.abs(rel * 100)) : Math.abs(rel * 100).toFixed(1)}%` : "new";
    return `<i class="bd-d ${cls}">${d > 0 ? "▲" : "▼"}${pct}</i>`;
  }

  label(id) { return this.shown?.nodes.find((n) => n.id === id)?.label ?? id; }

  // a member's name: node@.c.d for a cluster member, the app's label for
  // an app on one undistributed node (its key is just the app's id)
  nodeName(key, app) { const k = key.slice(5); return k.includes("@") ? shortNode(k) : this.label(app); }

  // ---- drawing -----------------------------------------------------------

  render() {
    if (!this.shown) return;
    this.renderIndex();
    this.renderChyron();
    this.renderCrawl();
    if (this.open) this.renderMonitor(false);
  }

  renderIndex() {
    const beams = this.keys("beam:"), repos = this.keys("repo:"), pgs = this.keys("pg:");
    const procs = this.agg(beams, "procs"), mem = this.agg(beams, "mem"), reds = this.agg(beams, "reds");
    const rq = this.agg(beams, "rq", true), mbox = this.agg(beams, "mbox", true), dist = this.agg(beams, "dist_out");
    const q = this.agg(repos, "rate"), conns = this.agg(pgs, "conns");
    // the mailbox's owner, for its tooltip
    let boxOwner = null;
    for (const k of beams) { const m = this.latest(k); if (m && isNum(m.mbox) && m.mbox === mbox[0]) boxOwner = `${shortName(m.mbox_name)} on ${shortNode(k.slice(5))}`; }
    const since = (this.shownAt ?? Date.now()) - MOVE;
    const errors = this.wireUpTo().filter((w) => w.at >= since && (w.kind === "error" || w.kind === "failing")).length;
    const calm = this.calm();
    const tile = (l, field, [n, t], title) => `<span class="ix"${title ? ` title="${esc(title)}"` : ""}><b>${l}</b><em>${n == null ? "–" : FMT[field](n)}</em>${this.delta(field, n, t)}</span>`;
    this.index.innerHTML = !beams.length ? `<span class="ix"><b>BEAM</b><em>–</em><i class="bd-d flat">no BEAM reports on the tape yet</i></span>` :
      tile("PROCS", "procs", procs, `processes on ${beams.length} BEAM nodes`) +
      tile("RUN Q", "rq", rq, "the longest run queue on any node") +
      tile("BEAM MEM", "mem", mem) +
      tile("REDS", "reds", reds, "reductions per second, all nodes") +
      tile("MBOX", "mbox", mbox, boxOwner ? `biggest mailbox: ${boxOwner}` : "biggest mailbox (needs the observer engine)") +
      tile("DIST", "dist_out", dist, "distribution traffic out, all nodes") +
      tile("REPO", "rate", q, "Repo queries per second") +
      tile("PG CONN", "conns", conns, "connections to the apps' own databases") +
      `<span class="ix${errors ? " hot" : ""}"><b>ERRORS</b><em>${errors}</em><i class="bd-d ${errors ? "dn" : "flat"}">5m</i></span>` +
      `<span class="ix calm${calm?.burning ? " burning" : ""}"><b>${calm?.burning ? "BURNING" : "CALM"}</b><em>${calm ? ago(calm.ms) + (calm.atLeast ? "+" : "") : "–"}</em></span>`;
  }

  // how long the floor has been calm, or burning, at the moment on screen
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
    return { burning, ms: at - b[i][0], atLeast: i === 0 };
  }

  // the stories: the wire's last 10 minutes at the moment on screen, worst first
  stories() {
    const at = this.shownAt ?? Date.now();
    return this.aired().filter((w) => w.at >= at - STORY_MS)
      .sort((a, b) => (SEV_RANK[a.sev] ?? 3) - (SEV_RANK[b.sev] ?? 3) || b.at - a.at).slice(0, 8);
  }

  renderChyron() {
    if (!this.shown) return;
    const replay = this.api.timeline.replaying;
    const bug = this.news.querySelector(".nw-bug");
    bug.textContent = replay ? "REPLAY" : "LIVE";
    bug.classList.toggle("replay", replay);
    const head = this.news.querySelector(".nw-head"), chy = this.news.querySelector(".nw-chyron");
    const air = this.airSet();
    const tag = this.news.querySelector(".nw-tag");
    tag.textContent = air ? `BEAM · ${air.name.toUpperCase()}` : "BEAM";
    tag.classList.toggle("air", !!air);
    const st = this.stories();
    if (!st.length) {
      const beams = this.keys("beam:");
      const apps = new Set(beams.map((k) => this.latest(k)?.app));
      const [procs] = this.agg(beams, "procs");
      const leads = beams.flatMap((k) => (this.latest(k)?.leads ?? []).filter((n) => !/Swoosh/.test(n)).map((n) => `${shortName(n)} led by ${shortNode(k.slice(5))}`));
      chy.dataset.level = "calm";
      head.innerHTML = beams.length
        ? `<b>BEAM QUIET</b> <span>${apps.size} app${apps.size === 1 ? "" : "s"} · ${beams.length} nodes · ${num(procs)} processes${leads.length ? ` · ${esc(leads.slice(0, 2).join(" · "))}` : ""}</span>`
        : `<b>NO BEAM ON THE TAPE</b> <span>no app reports a BEAM runtime yet</span>`;
      return;
    }
    const w = st[this.story % st.length];
    chy.dataset.level = w.sev === "alert" ? "alert" : w.sev === "warn" ? "warn" : "info";
    head.innerHTML = `<b data-wire="${esc(String(w.id ?? w.key))}">${esc((w.label ?? w.app ?? "").toUpperCase())} · ${esc(w.head)}</b> <span>${esc(w.text ?? "")} · ${ago((this.shownAt ?? Date.now()) - w.at)} ago</span>${st.length > 1 ? ` <i>${(this.story % st.length) + 1}/${st.length}</i>` : ""}`;
  }

  renderClock() {
    const c = this.news.querySelector(".nw-clock");
    const at = this.api.timeline.replaying ? this.api.timeline.cursor : Date.now();
    if (at == null) return;
    c.innerHTML = `${hms(at)} <span>UTC ${new Date(at).toLocaleDateString("en-GB", { timeZone: "UTC", day: "numeric", month: "short" }).toUpperCase()}</span>`;
  }

  renderCrawl() {
    const parts = [];
    const recent = this.aired().slice(0, 6);
    for (const k of this.keys("beam:")) {
      const m = this.latest(k);
      const [p, p0] = this.move(k, "procs");
      const star = (m.leads ?? []).filter((n) => !/Swoosh/.test(n)).map((n) => `★${shortName(n).split(".").pop().toUpperCase()}`).join(" ");
      parts.push(`<span class="cr" data-node="${esc(m.app)}"><b>${esc(this.nodeName(k, m.app).toUpperCase())}</b>${star ? ` <em>${esc(star)}</em>` : ""} ${FMT.procs(p)} procs ${this.delta("procs", p, p0)} · rq ${num(m.rq)}/${num(m.sched)} · ${bytes(m.mem)} · ${num(m.reds)} red/s${isNum(m.mbox) ? ` · mbox ${num(m.mbox)}` : ""} · ⇄${num(m.peers ?? 0)}</span>`);
    }
    for (const k of this.keys("repo:")) {
      const m = this.latest(k);
      const [r, r0] = this.move(k, "rate");
      parts.push(`<span class="cr db" data-node="${esc(m.app)}"><b>${esc(shortName(m.name ?? k.slice(5)).toUpperCase())}</b> ${FMT.rate(r)} ${this.delta("rate", r, r0)}${isNum(m.ms) ? ` · ${num(m.ms)} ms` : ""}${m.err ? ` · <span class="bad">${Math.round(m.err * 100)}% err</span>` : ""}</span>`);
    }
    for (const k of this.keys("pg:")) {
      const m = this.latest(k);
      const [c, c0] = this.move(k, "conns");
      parts.push(`<span class="cr db" data-node="db"><b>${esc(k.slice(3).toUpperCase())}</b> ${num(c)} conns ${this.delta("conns", c, c0)} · ${num(m.commits)} commits/s</span>`);
    }
    for (const w of recent) parts.push(`<span class="cr wire ${esc(w.sev)}" data-wire="${esc(String(w.id ?? w.key))}"><b>${hms(w.at).slice(0, 5)} ${esc((w.label ?? w.app ?? "").toUpperCase())}</b> ${esc(w.head)}</span>`);
    const html = parts.join("");
    const track = this.news.querySelector(".nw-track");
    if (track.dataset.html === html) return;
    track.dataset.html = html;
    track.innerHTML = `<div class="nw-run">${html}</div><div class="nw-run" aria-hidden="true">${html}</div>`;
    const w = track.firstElementChild.scrollWidth;
    if (Math.abs((this.crawlW ?? 0) - w) > 40) { this.crawlW = w; track.style.setProperty("--crawl-s", `${Math.max(25, w / 55)}s`); }
  }

  spark(key, field) {
    const pts = this.upTo().map(([t, m]) => [t, m[key]?.[field]]).filter(([, v]) => isNum(v));
    if (pts.length < 2) return `<svg class="sp" viewBox="0 0 80 16"></svg>`;
    const t0 = pts[0][0], t1 = pts[pts.length - 1][0];
    let lo = Infinity, hi = -Infinity;
    for (const [, v] of pts) { if (v < lo) lo = v; if (v > hi) hi = v; }
    const span = hi - lo || 1;
    const d = pts.map(([t, v], i) => `${i ? "L" : "M"}${(((t - t0) / (t1 - t0 || 1)) * 80).toFixed(1)},${(15 - ((v - lo) / span) * 14).toFixed(1)}`).join("");
    return `<svg class="sp" viewBox="0 0 80 16" preserveAspectRatio="none"><path d="${d}"/></svg>`;
  }

  // force: a person did something here (a click, a save, a set arriving);
  // without it, a live tick, which must not pull an input out from under
  // someone typing in the board: then only the wire list is redrawn
  renderMonitor(force = true) {
    if (!this.shown) { this.el.innerHTML = ""; return; }
    const at = this.shownAt ? hms(this.shownAt) : "";
    const tabs = [["wire", `Wire <b>${this.wireUpTo().length}</b>`], ["beam", `BEAM <b>${this.keys("beam:").length}</b>`], ["db", "DB"]];
    const head = `<div class="bd-head"><h3>Board</h3><div class="bd-tabs" role="tablist">${tabs.map(([k, l]) => `<button type="button" role="tab" data-tab="${k}" aria-selected="${this.tab === k}">${l}</button>`).join("")}</div>
      <span class="bd-at">${this.api.timeline.replaying ? "REPLAY" : "LIVE"} ${at}</span><button type="button" class="fi-x" data-a="close" aria-label="Close">×</button></div>`;
    const active = this.el.contains(document.activeElement) && typing(document.activeElement) ? document.activeElement : null;
    if (active && !force) { if (this.tab === "wire") this.renderWireList(); return; }
    // the search box keeps its cursor across a redraw
    const keep = active?.name === "wq" ? [active.selectionStart, active.selectionEnd] : null;
    const body = this.tab === "wire" ? this.wireTab() : this.tab === "beam" ? this.beamTab() : this.dbTab();
    this.el.innerHTML = head + body;
    if (this.tab === "wire") this.renderWireList();
    if (keep) { const i = this.el.querySelector("input[name=wq]"); i?.focus(); i?.setSelectionRange(...keep); }
  }

  wireTab() {
    const all = this.wireUpTo();
    const f = this.filter;
    const count = (pred) => all.filter(pred).length;
    const chip = (k, v, l, n) => `<button type="button" class="bd-chip${f[k].includes(v) ? " on" : ""}" data-f="${k}:${esc(v)}">${esc(l)}${n != null ? ` <i>${n}</i>` : ""}</button>`;
    const apps = [...new Set(all.map((w) => w.app).filter(Boolean))];
    const kinds = [...new Set(all.map((w) => w.kind))].sort();
    const cur = this.sets.find((x) => x.id === this.setId);
    const dirty = cur && !sameSpec(f, cur.spec);
    const any = f.apps.length || f.sevs.length || f.kinds.length || f.q.trim();
    const sets = this.sets.map((x) => `<span class="bd-set${x.id === this.setId ? " on" : ""}${String(x.id) === this.air ? " aired" : ""}" data-set="${x.id}" title="${esc(this.describe(x.spec))}${x.by ? ` · saved by ${esc(x.by)}` : ""}">
        <button type="button" class="nm">${esc(x.name)} <i>${count((w) => matches(x.spec, w))}</i></button><button type="button" class="air" data-sa="air" title="${String(x.id) === this.air ? "Off air: the chyron and crawl show the whole wire" : "On air: the chyron and crawl show only this set (on this screen)"}">${String(x.id) === this.air ? "ON AIR" : "air"}</button><button type="button" class="del" data-sa="del" aria-label="Delete ${esc(x.name)}">×</button></span>`).join("");
    return `<div class="bd-sets">${sets || `<span class="bd-hint">No saved sets yet. Filter below, then Save as set.</span>`}</div>
      <div class="bd-filters">
        <input name="wq" type="search" placeholder="search head, detail, node" value="${esc(f.q)}" aria-label="Search the wire" spellcheck="false">
        ${chip("sevs", "alert", "alerts", count((w) => w.sev === "alert"))}${chip("sevs", "warn", "warnings", count((w) => w.sev === "warn"))}${chip("sevs", "info", "info", count((w) => w.sev === "info"))}
      </div>
      <div class="bd-filters">${apps.map((a) => chip("apps", a, this.label(a), count((w) => w.app === a))).join("")}</div>
      ${kinds.length ? `<div class="bd-filters kinds">${kinds.map((k) => chip("kinds", k, k, count((w) => w.kind === k))).join("")}</div>` : ""}
      <div class="bd-setbar">
        ${this.naming ? `<form data-form="set" class="tl-form"><input name="name" maxlength="60" placeholder="name this set" value="${esc(this.suggest())}" aria-label="Set name"><button type="submit" class="go">Save</button><button type="button" data-sa="cancel">Cancel</button></form>`
          : `${any ? `<button type="button" data-f="all:">clear</button>` : ""}${dirty ? `<button type="button" class="go" data-sa="update">Update “${esc(cur.name)}”</button>` : ""}${any && (!cur || dirty) ? `<button type="button" data-sa="saveas">Save as set</button>` : ""}`}
        <span class="bd-n"></span>
      </div>
      <ol class="bd-wire"></ol>
      <p class="bd-empty" hidden></p>`;
  }

  // the list under the filter: drawn on its own so typing a search keeps
  // the cursor in the box
  renderWireList() {
    const ol = this.el.querySelector("ol.bd-wire");
    if (!ol) return;
    const all = this.wireUpTo();
    const items = all.filter((w) => matches(this.filter, w)).slice(0, 300);
    ol.innerHTML = items.map((w) => `<li class="${esc(w.sev)}" data-wire="${esc(String(w.id ?? w.key))}" title="Replay this moment">
          <span class="t">${hms(w.at)}</span><span class="k">${esc(w.kind)}</span>
          <div><b>${esc(w.label ?? w.app ?? "")}</b> ${esc(w.head)}${w.member ? ` <span class="m">${esc(shortNode(w.member))}</span>` : ""}<div class="x">${esc(w.text ?? "")}</div></div></li>`).join("");
    const n = this.el.querySelector(".bd-n");
    if (n) n.textContent = `${items.length} of ${all.length}`;
    const empty = this.el.querySelector(".bd-empty");
    empty.hidden = items.length > 0;
    empty.textContent = all.length
      ? "Nothing on the wire matches this filter."
      : "Nothing on the wire in the last 6 hours up to this moment. It reports restarts, joins and partitions, leaders moving, run queues, memory and atom jumps, mailboxes of 100+, logged errors, failing or surging Repo queries, and the apps' databases.";
  }

  describe(spec) {
    const p = [];
    if (spec.apps?.length) p.push(spec.apps.map((a) => this.label(a)).join(", "));
    if (spec.sevs?.length) p.push(spec.sevs.join("/"));
    if (spec.kinds?.length) p.push(spec.kinds.join(", "));
    if (spec.q) p.push(`“${spec.q}”`);
    return p.join(" · ") || "everything";
  }

  suggest() { return this.describe(this.filter).slice(0, 60); }

  beamTab() {
    const keys = this.keys("beam:");
    if (!keys.length) return `<p class="bd-empty">No BEAM node on the tape at this moment.</p>`;
    const byApp = new Map();
    for (const k of keys) { const m = this.latest(k); if (!byApp.has(m.app)) byApp.set(m.app, []); byApp.get(m.app).push([k, m]); }
    const rows = [...byApp].map(([app, list]) => `<tr class="grp" data-node="${esc(app)}"><td colspan="9">${esc(this.label(app))} <span class="dim">${list.length} node${list.length === 1 ? "" : "s"}</span></td></tr>` +
      list.map(([k, m]) => {
        const [p, p0] = this.move(k, "procs");
        const hot = isNum(m.rq) && isNum(m.sched) && m.rq > m.sched;
        return `<tr data-node="${esc(app)}"><td class="nm" title="${esc(k.slice(5))}">${esc(this.nodeName(k, app))}${(m.leads ?? []).filter((n) => !/Swoosh/.test(n)).map((n) => ` <em title="leads ${esc(n)}">★${esc(shortName(n).split(".").pop())}</em>`).join("")}</td>
          <td class="r">${num(p)} ${this.delta("procs", p, p0)}</td><td>${this.spark(k, "procs")}</td>
          <td class="r${hot ? " bad" : ""}">${num(m.rq)}/${num(m.sched)}</td><td class="r">${bytes(m.mem)}</td><td class="r">${bytes(m.bin)}</td>
          <td class="r">${num(m.reds)}/s</td><td class="r${(m.mbox ?? 0) >= 100 ? " bad" : ""}" title="${esc(shortName(m.mbox_name ?? ""))}">${isNum(m.mbox) ? num(m.mbox) : "–"}</td>
          <td class="r">${bytes(m.dist_out ?? 0)}/s${(m.sendq ?? 0) > 0 ? ` <span class="bad">q ${bytes(m.sendq)}</span>` : ""} · ${up(m.up)}</td></tr>`;
      }).join("")).join("");
    return `<table><thead><tr><th>node</th><th class="r">procs</th><th>15m</th><th class="r">run q</th><th class="r">mem</th><th class="r">binary</th><th class="r">reds</th><th class="r">mbox</th><th class="r">dist out · up</th></tr></thead><tbody>${rows}</tbody></table>
      <p class="bd-foot">★ marks what a node leads (a :global name). Run queue over schedulers is red: more runnable processes than CPUs. mbox is the biggest mailbox, from the observer engine where the app has it.</p>`;
  }

  dbTab() {
    const repos = this.keys("repo:"), pgs = this.keys("pg:");
    if (!repos.length && !pgs.length) return `<p class="bd-empty">No Repo stream or app database on the tape at this moment.</p>`;
    const r = repos.map((k) => {
      const m = this.latest(k); const [v, v0] = this.move(k, "rate");
      return `<tr data-node="${esc(m.app)}"><td class="nm">${esc(this.label(m.app))} <span class="dim">${esc(shortName(m.name ?? ""))}</span></td><td class="r">${FMT.rate(v)} ${this.delta("rate", v, v0)}</td><td>${this.spark(k, "rate")}</td><td class="r">${isNum(m.ms) ? `${num(m.ms)} ms` : "–"}</td><td class="r${m.err ? " bad" : ""}">${isNum(m.err) ? `${Math.round(m.err * 100)}%` : "–"}</td></tr>`;
    }).join("");
    const p = pgs.map((k) => {
      const m = this.latest(k); const [c, c0] = this.move(k, "conns"); const [x, x0] = this.move(k, "commits");
      return `<tr data-node="db"><td class="nm">${esc(k.slice(3))} <span class="dim">${esc(this.label(m.app))}</span></td><td class="r">${num(c)} ${this.delta("conns", c, c0)}</td><td>${this.spark(k, "conns")}</td><td class="r">${num(x)}/s ${this.delta("commits", x, x0)}</td><td>${this.spark(k, "commits")}</td></tr>`;
    }).join("");
    return `${repos.length ? `<h4>Repo, as each app reports it</h4><table><thead><tr><th>app</th><th class="r">queries</th><th>15m</th><th class="r">avg</th><th class="r">errors</th></tr></thead><tbody>${r}</tbody></table>` : ""}
      ${pgs.length ? `<h4>Each app's Postgres database</h4><table><thead><tr><th>database</th><th class="r">conns</th><th>15m</th><th class="r">commits</th><th>15m</th></tr></thead><tbody>${p}</tbody></table>` : ""}`;
  }
}
