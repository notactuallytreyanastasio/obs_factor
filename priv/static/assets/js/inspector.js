// The inspector: bottom sheet on a phone, side panel on a desktop.

import { num, bytes, bps, withUnit, duration, esc, isNum, UNKNOWN, utc } from "./fmt.js";
import { headlineText } from "./overlay.js";
import { itemColor, HOLD_COLORS, CPU_COLOR, MEM_COLOR, STATUS_COLOR, CLASS_COLOR, containerPlan } from "./render.js";
import * as bus from "./bus.js";

const $ = (id) => document.getElementById(id);
const u = (v, f = (x) => x) => (v == null ? `<span class="unk">${UNKNOWN}</span>` : esc(f(v)));

export class Inspector {
  constructor({ onClose, onNavigate, onExplore }) {
    this.el = $("inspector");
    this.body = $("inspector-body");
    this.onClose = onClose;
    this.onNavigate = onNavigate;
    this.id = null;
    this.res = "5s";
    this.hist = null;
    this.histErr = null;
    this.histUnsub = null;
    $("inspector-close").addEventListener("click", () => this.close());
    this.body.innerHTML = '<div class="live"></div><div class="sec buildlog" hidden></div><div class="sec hist"></div>';
    this.live = this.body.querySelector(".live");
    this.logEl = this.body.querySelector(".buildlog");
    this.buildId = null;
    this.buildUnsub = null;
    this.histEl = this.body.querySelector(".hist");
    this.logEl.addEventListener("click", (e) => {
      if (!this.buildId || window.getSelection()?.toString()) return;
      if (e.target.closest("pre, .lx-open")) onExplore?.({ service: ["builder"], job: [this.buildId] });
    });
    this.live.addEventListener("click", (e) => {
      const a = e.target.closest("[data-goto]");
      if (a) { e.preventDefault(); this.onNavigate(a.dataset.goto); }
    });
    this.histEl.addEventListener("click", (e) => {
      const b = e.target.closest("[data-res]");
      if (b && b.dataset.res !== this.res) { this.res = b.dataset.res; this.hist = null; this.renderHistory(); this.loadHistory(); }
    });
    // drag the sheet's grab bar up to make it tall, down to close
    const grab = this.el.querySelector(".grab");
    let y0 = null;
    grab.addEventListener("pointerdown", (e) => { y0 = e.clientY; grab.setPointerCapture(e.pointerId); });
    grab.addEventListener("pointerup", (e) => {
      if (y0 == null) return;
      const dy = e.clientY - y0; y0 = null;
      if (dy < -40) this.el.classList.add("tall");
      else if (dy > 60) { if (this.el.classList.contains("tall")) this.el.classList.remove("tall"); else this.close(); }
    });
    window.addEventListener("keydown", (e) => { if (e.key === "Escape" && this.id) this.close(); });
  }

  get open() { return this.id != null; }

  // history: false for nodes the observer keeps no series for (the inside of a building)
  show(id, snap, { history = true } = {}) {
    const changed = id !== this.id || history !== this.history;
    this.id = id;
    this.history = history;
    this.el.hidden = false;
    document.body.classList.add("inspecting");
    if (changed) {
      this.hist = null; this.histErr = null;
      this.body.scrollTop = 0;
      this.renderHistory();
      this.loadHistory();
    }
    this.update(snap);
  }

  close() {
    if (!this.id) return;
    this.id = null;
    this.el.hidden = true;
    this.el.classList.remove("tall");
    document.body.classList.remove("inspecting");
    this.histUnsub?.(); this.histUnsub = null;
    this.syncBuild(null);
    this.onClose();
  }

  update(snap) {
    if (!this.id) return;
    this.snap = snap;
    const n = snap.nodes.find((x) => x.id === this.id);
    this.syncBuild(n);
    if (!n) {
      this.live.innerHTML = `<div class="ins-head"><h2>${esc(this.id)}</h2></div><p class="note err">This node is no longer in the snapshot.</p>`;
      return;
    }
    this.live.innerHTML = [head(n), build(n), facts(n), holds(n), power(n, snap), drawnBy(n, snap), inside(n), flows(n, snap), latency(n), clients(n), hostsTable(n), routes(n, snap), via(n), probe(n), container(n)].join("");
  }

  // The build's log is not in the snapshot: the feed builds:<id> on the
  // socket (the builder's job, read every 2 s on the server while someone
  // watches). Once the job has finished and been shown, we leave the topic.
  syncBuild(n) {
    const id = n?.build?.id ?? null;
    if (id === this.buildId) {
      if (id && n.build.status === "running" && !this.buildUnsub) this.loadBuild();
      return;
    }
    this.buildUnsub?.(); this.buildUnsub = null;
    this.buildId = id;
    this.logEl.hidden = !id;
    if (id) { this.logEl.innerHTML = '<h3>Build log</h3><p class="note">Loading…</p>'; this.loadBuild(); }
  }

  loadBuild() {
    const id = this.buildId;
    if (!id || this.buildUnsub) return;
    const take = (p) => {
      if (id !== this.buildId || !p.at) return;
      this.renderBuild(p.data, p.error);
      if (p.data && p.data.status !== "running") { this.buildUnsub?.(); this.buildUnsub = null; }
    };
    this.buildUnsub = bus.subscribe(`builds:${id}`, (ev, p) => ev === "feed" && take(p), {
      onJoin: take,
      onError: (reason) => { if (id === this.buildId) this.renderBuild(null, `builds:${id} refused: ${reason}`); },
    });
  }

  renderBuild(job, error) {
    const pre = this.logEl.querySelector("pre");
    const stuck = !pre || pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 8;
    if (error) this.logEl.innerHTML = `<h3>Build log</h3><p class="note err">${esc(error)}</p>`;
    else {
      const lines = job.log.slice(-150).map((l) => `<span class="st">${esc(l.step)}</span>${esc(l.line)}`).join("\n");
      const plan = job.plan_summary;
      this.logEl.innerHTML = (plan ? `<h3>The agent's plan</h3><p class="plan-sum">${esc(plan.summary)}</p>${plan.notes ? `<p class="note">${esc(plan.notes)}</p>` : ""}` : "") +
        `<h3>Build log <span class="unk">${job.log.length} lines</span><button type="button" class="lx-open">Search ↗</button></h3><pre title="Click to search this log">${lines || "nothing yet"}</pre>`;
      const p2 = this.logEl.querySelector("pre");
      if (stuck) p2.scrollTop = p2.scrollHeight;
    }
  }

  // The series behind the charts: the feed history:<id>:<res> (re-read on
  // the server every 15 s for 1 h, every 60 s for 24 h).
  loadHistory() {
    this.histUnsub?.(); this.histUnsub = null;
    const id = this.id, res = this.res;
    if (!id) return;
    if (!this.history) { this.hist = { series: [] }; this.histErr = null; this.renderHistory(); return; }
    const take = (p) => {
      if (id !== this.id || res !== this.res || !p.at) return;
      if (p.error) this.histErr = p.error;
      else { this.hist = p.data; this.histErr = null; }
      this.renderHistory();
    };
    this.histUnsub = bus.subscribe(`history:${id}:${res}`, (ev, p) => ev === "feed" && take(p), {
      onJoin: take,
      onError: (reason) => { if (id === this.id) { this.histErr = `history refused: ${reason}`; this.renderHistory(); } },
    });
  }

  renderHistory() {
    const seg = `<span class="seg" role="group" aria-label="History range">
      <button data-res="5s" aria-pressed="${this.res === "5s"}">1 h</button><button data-res="1m" aria-pressed="${this.res === "1m"}">24 h</button></span>`;
    let inner;
    if (this.histErr) inner = `<p class="note err">${esc(this.histErr)}</p>`;
    else if (!this.hist) inner = '<p class="note">Loading…</p>';
    else if (!this.hist.series.length) inner = `<p class="note">${this.history ? "No series for this node." : "No history is kept for things inside a building yet."}</p>`;
    else inner = this.hist.series.map((s, i) => `<div class="chart" data-i="${i}">
        <div class="ch-head"><span class="l">${esc(s.label)}</span><span class="v"></span></div>
        <canvas height="64"></canvas></div>`).join("");
    this.histEl.innerHTML = `<h3>History${seg}</h3><div class="charts">${inner}</div>`;
    if (this.hist && !this.histErr) {
      this.histEl.querySelectorAll(".chart").forEach((el) => drawChart(el, this.hist.series[+el.dataset.i], this.res));
    }
  }
}

// ---- sections -------------------------------------------------------------

function head(n) {
  const sub = [n.kind, n.container?.name ?? null, n.platform ? `on ${n.platform}` : n.kind === "source" ? null : "not in the topology"].filter(Boolean).join(" · ");
  return `<div class="ins-head">
    <h2>${esc(n.label)}</h2>
    <div class="sub">${esc(sub)}</div>
    <div class="status-pill st-${esc(n.status)}"><span class="lamp ${esc(n.status)}" style="background:${n.status === "unknown" ? "transparent" : STATUS_COLOR[n.status] ?? "#888"}"></span>${esc(n.status)}<span class="unk" style="font-weight:500;margin-left:6px">${esc(headlineText(n.headline))}</span></div>
    ${n.reason ? `<div class="reason">${esc(n.reason)}</div>` : ""}
  </div>`;
}

const STEP_MARK = { done: "✓", failed: "✕", running: "●", pending: "·" };

function build(n) {
  const b = n.build;
  if (!b) return "";
  const steps = (b.steps || []).map((s) => `<li class="bs ${esc(s.state)}"><span class="mk" aria-hidden="true">${STEP_MARK[s.state] ?? "?"}</span><b>${esc(s.name)}</b><span class="nt">${s.note ? esc(s.note) : ""}</span></li>`).join("");
  const src = b.repo ? `<p class="src"><a href="${esc(b.repo)}" target="_blank" rel="noopener noreferrer">${esc(b.repo.replace("https://github.com/", ""))}</a>${b.ref ? ` @ ${esc(b.ref)}` : ""}${b.commit ? ` <span class="unk">${esc(b.commit.slice(0, 12))}</span>` : ""}</p>` : "";
  const state = b.status === "running" ? `building: ${esc(b.step)}` : b.status === "failed" ? `failed at ${esc(b.step)}` : b.mode === "route" ? "lot reserved" : "live";
  return `<div class="sec build"><h3>Build <span class="unk">${esc(b.id)}</span></h3>
    <p class="bstate ${esc(b.status)}">${state} · <a href="http://${esc(b.fqdn)}" target="_blank" rel="noopener noreferrer">${esc(b.fqdn)}</a></p>
    ${src}<ol class="steps">${steps}</ol>${b.error ? `<p class="note err">${esc(b.error)}</p>` : ""}</div>`;
}

function facts(n) {
  if (!n.facts?.length) return "";
  return `<div class="sec"><h3>Facts</h3><dl class="kv">${n.facts.map((f) => `<dt>${esc(f.label)}</dt><dd>${u(f.value)}</dd>`).join("")}</dl></div>`;
}

function holds(n) {
  if (!n.holds?.length) return "";
  const list = [...n.holds].sort((a, b) => (b.bytes ?? -1) - (a.bytes ?? -1));
  const known = list.filter((h) => isNum(h.bytes));
  const total = known.reduce((a, h) => a + h.bytes, 0);
  const color = (i) => HOLD_COLORS[i % HOLD_COLORS.length];
  // keep the colour a hold has in the db silo bands (snapshot order)
  const idx = new Map(n.holds.map((h, i) => [h.label, i]));
  const bar = total > 0 ? `<div class="stack">${known.map((h) => `<span style="flex:${h.bytes / total};background:${color(idx.get(h.label))}" title="${esc(h.label)}"></span>`).join("")}</div>` : "";
  const plan = n.kind === "db" ? containerPlan(n.holds) : null;
  const yard = plan?.unit ? `<p class="note">In the yard, one container is ${esc(bytes(plan.unit))}.</p>` : "";
  return `<div class="sec"><h3>Holds</h3>${bar}${yard}<ul class="keyed">${list.map((h) => `<li style="--c:${color(idx.get(h.label))}"><span class="sw"></span>${esc(h.label)}<span class="v">${u(h.bytes, bytes)}</span></li>`).join("")}</ul></div>`;
}

function power(n, snap) {
  const c = n.container;
  if (!c) return "";
  const host = snap.host;
  const cpuF = isNum(c.cpu_cores) && host.cores ? c.cpu_cores / host.cores : null;
  const memOf = isNum(c.mem_limit_bytes) ? c.mem_limit_bytes : host.mem_total_bytes;
  const memF = isNum(c.mem_bytes) && memOf ? c.mem_bytes / memOf : null;
  const bar = (f, col) => `<span class="bar" style="--c:${col}"><span style="width:${f == null ? 0 : Math.max(2, Math.min(100, f * 100))}%"></span></span>`;
  return `<div class="sec"><h3>Power drawn</h3><ul class="keyed power">
    <li style="--c:${CPU_COLOR}"><span class="sw"></span>CPU ${bar(cpuF, CPU_COLOR)}<span class="v">${isNum(c.cpu_cores) ? `${esc(num(c.cpu_cores))} cores` : `<span class="unk">${UNKNOWN}</span>`}</span></li>
    <li style="--c:${MEM_COLOR}"><span class="sw"></span>Memory ${bar(memF, MEM_COLOR)}<span class="v">${u(c.mem_bytes, bytes)}${isNum(c.mem_limit_bytes) ? ` <span class="unk">of ${esc(bytes(c.mem_limit_bytes))}</span>` : ""}</span></li>
  </ul></div>`;
}

// For host-cpu / host-mem: who draws the most.
function drawnBy(n, snap) {
  if (n.id !== "host-cpu" && n.id !== "host-mem") return "";
  const cpu = n.id === "host-cpu";
  const rows = snap.nodes.filter((x) => x.container).map((x) => [x, cpu ? x.container.cpu_cores : x.container.mem_bytes]);
  rows.sort((a, b) => (b[1] ?? -1) - (a[1] ?? -1));
  const host = snap.host;
  const total = cpu ? `${u(host.cpu_used_cores, num)} of ${u(host.cores)} cores` : `${u(host.mem_used_bytes, bytes)} of ${u(host.mem_total_bytes, bytes)}`;
  return `<div class="sec"><h3>Whole host</h3><p style="margin:0 0 10px;font-family:var(--mono)">${total}${cpu && isNum(host.load1) ? ` · load ${esc(num(host.load1))}` : ""}</p>
    <h3>Drawn by</h3><ul class="keyed">${rows.slice(0, 12).map(([x, v]) => `<li style="--c:${cpu ? CPU_COLOR : MEM_COLOR}"><span class="sw"></span><a data-goto="${esc(x.id)}" href="#">${esc(x.label)}</a><span class="v">${v == null ? `<span class="unk">${UNKNOWN}</span>` : esc(cpu ? `${num(v)} cores` : bytes(v))}</span></li>`).join("")}</ul></div>`;
}

function flows(n, snap) {
  const ins = snap.edges.filter((e) => e.to === n.id);
  const outs = snap.edges.filter((e) => e.from === n.id);
  const label = (id) => snap.nodes.find((x) => x.id === id)?.label ?? id;
  const row = (e, other, dir) => {
    const rate = !e.metered ? '<span class="unk">not metered</span>' : isNum(e.rate) ? esc(withUnit(e.rate, e.unit ?? "/s")) : `<span class="unk">${UNKNOWN}${e.unit ? ` ${esc(e.unit)}` : ""}</span>`;
    return `<li style="--c:${itemColor(e.item)}"><span class="ic${e.metered ? "" : " dashed"}"></span>
      <a data-goto="${esc(other)}" href="#"><div class="t">${dir} ${esc(label(other))}</div><div class="s">${esc(e.item)}${e.label ? ` · ${esc(e.label)}` : ""}</div></a>
      <span class="v">${rate}</span></li>`;
  };
  let out = "";
  if (ins.length) out += `<div class="sec"><h3>In</h3><ul class="keyed flows">${ins.map((e) => row(e, e.from, "from")).join("")}</ul></div>`;
  if (outs.length) out += `<div class="sec"><h3>Out</h3><ul class="keyed flows">${outs.map((e) => row(e, e.to, "to")).join("")}</ul></div>`;
  return out;
}

// One block per hostname: rate and latency, then what came back by status
// class (the colours of the items on the belt), bytes and what is in flight.
function hostsTable(n) {
  if (!n.hosts?.length) return "";
  const ms = (v) => (isNum(v) ? `${num(v)} ms` : null);
  const classes = Object.keys(CLASS_COLOR);
  const block = (h) => {
    const known = h.codes && classes.some((k) => isNum(h.codes[k]));
    const total = known ? classes.reduce((a, k) => a + (isNum(h.codes[k]) ? h.codes[k] : 0), 0) : 0;
    const bar = total > 0
      ? `<div class="stack codes">${classes.filter((k) => h.codes[k] > 0).map((k) => `<span style="flex:${h.codes[k] / total};background:${CLASS_COLOR[k]}" title="${k}"></span>`).join("")}</div>`
      : "";
    const mix = known
      ? classes.filter((k) => k !== "other" || h.codes[k] > 0).map((k) => `<span class="cls" style="--c:${CLASS_COLOR[k]}"><i></i>${k} ${u(h.codes[k], num)}</span>`).join("")
      : `<span class="unk">status classes unknown</span>`;
    return `<div class="host">
      <div class="hrow"><span class="hname">${esc(h.host)}</span><span class="v">${u(h.rps, num)} <span class="unk">req/s</span></span></div>
      ${bar}<div class="hmix">${mix}</div>
      <div class="hmeta"><span>avg ${u(ms(h.avg_ms))}</span><span>out ${u(h.out_bps, bps)}</span><span>in ${u(h.in_bps, bps)}</span><span>${u(h.in_flight)} in flight</span></div>
    </div>`;
  };
  return `<div class="sec"><h3>Hosts</h3>${n.hosts.map(block).join("")}</div>`;
}

// From the sub-app's own report (docs/contract.md, Reports): its runtime, the
// things alive inside it, and what happens there. Generic: the keys and kinds
// are whatever the app reports; nothing here knows what Phoenix is.
const KIND_LABEL = { liveview: "LiveView pages", channel: "Channels" };
const STREAM_COLOR = { "http.route": "#ffd166", "liveview.event": "#4cc9f0", "liveview.mount": "#6ab7ff", "liveview.params": "#6ab7ff",
  "db.query": "#43aa8b", "outbound.http": "#f472b6", "channel.join": "#b388ff", "channel.event": "#b388ff", custom: "#f9844a" };
const gaugeText = (k, v) => (!isNum(v) ? UNKNOWN : /^memory\b|memory$|_bytes$/.test(k) ? bytes(v) : k.endsWith("utilization") ? `${(v * 100).toFixed(1)}%` : num(v));
const ago = (iso) => { const s = (Date.now() - Date.parse(iso)) / 1000; return Number.isFinite(s) ? duration(Math.max(0, s)) : UNKNOWN; };

// What the app logged at warning and above, newest first.
export function eventsList(events) {
  if (!events) return "";
  if (!events.length) return "";
  const col = { error: "#ff4d4d", critical: "#ff4d4d", alert: "#ff4d4d", emergency: "#ff4d4d", warning: "#ff9f1c" };
  return `<div class="sec"><h3>Logged <span class="h3note">warnings and errors, newest first</span></h3><ul class="logs">${events.map((e) => `<li style="--c:${col[e.level] ?? "#9aa5b8"}">
      <div class="lrow"><span class="llevel">${esc(e.level)}</span><span class="lname" title="${esc(e.name ?? "")}">${esc(e.name ?? "")}</span><time>${esc(ago(e.at))} ago</time></div>
      <div class="lmsg">${esc(e.message)}</div>${e.by ? `<div class="lby">while serving ${esc(e.by.name)}</div>` : ""}</li>`).join("")}</ul></div>`;
}

function inside(n) {
  const r = n.inside;
  if (!r) return "";
  if (!r.ok) {
    return `<div class="sec"><h3>Inside</h3><p class="note err">report failing: ${esc(r.error ?? "no error given")}${r.at ? ` (last read ${esc(utc(new Date(r.at)))})` : ""}</p></div>`;
  }
  const hasRuntime = r.runtime != null;
  const rt = r.runtime ?? {};
  const g = rt.gauges ?? {};
  const versions = Object.entries(rt.versions ?? {}).map(([k, v]) => `${esc(k)} ${esc(v)}`).join(" · ");
  const mem = Object.entries(g).filter(([k]) => k.startsWith("memory.") && k !== "memory.total").sort((a, b) => b[1] - a[1]);
  const memTotal = g["memory.total"];
  const memBar = isNum(memTotal) && mem.length
    ? `<div class="stack">${mem.map(([k, v], i) => `<span style="flex:${v / memTotal};background:${HOLD_COLORS[i % HOLD_COLORS.length]}" title="${esc(k)}"></span>`).join("")}</div>
       <ul class="keyed tight">${mem.map(([k, v], i) => `<li style="--c:${HOLD_COLORS[i % HOLD_COLORS.length]}"><span class="sw"></span>${esc(k.slice(7))}<span class="v">${esc(bytes(v))}</span></li>`).join("")}</ul>`
    : "";
  const other = Object.entries(g).filter(([k]) => !k.startsWith("memory."));
  const rates = Object.entries(rt.rates ?? {});
  let out = !hasRuntime ? "" : `<div class="sec"><h3>Inside: ${esc(rt.kind ?? "runtime")} <span class="h3note">up ${isNum(rt.uptime_s) ? esc(duration(rt.uptime_s)) : UNKNOWN}</span></h3>
    ${versions ? `<p class="note">${versions}</p>` : ""}
    <div class="pcts">
      <div class="pct"><span class="k">memory</span><span class="v">${esc(gaugeText("memory.total", memTotal))}</span></div>
      <div class="pct"><span class="k">processes</span><span class="v">${esc(gaugeText("process.count", g["process.count"]))}</span></div>
      <div class="pct"><span class="k">run queue</span><span class="v">${esc(gaugeText("run_queue", g.run_queue))}</span></div>
    </div>${memBar ? `<div style="margin-top:12px">${memBar}</div>` : ""}
    <dl class="kv small">${other.filter(([k]) => !["process.count", "run_queue"].includes(k)).map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(gaugeText(k, v))}</dd>`).join("")}
      ${rates.map(([k, v]) => `<dt>${esc(k)} /s</dt><dd>${v == null ? `<span class="unk">${UNKNOWN}</span>` : esc(/bytes$/.test(k) ? bytes(v) : num(v))}</dd>`).join("")}</dl></div>`;

  const byKind = new Map();
  for (const unit of r.units ?? []) { if (!byKind.has(unit.kind)) byKind.set(unit.kind, []); byKind.get(unit.kind).push(unit); }
  for (const [kind, units] of byKind) {
    const total = units.reduce((a, x) => a + (x.count ?? 0), 0);
    units.sort((a, b) => (b.count ?? 0) - (a.count ?? 0));
    out += `<div class="sec"><h3>${esc(KIND_LABEL[kind] ?? kind)} <span class="h3note">${esc(num(total))} alive now</span></h3><ul class="units">${units.map((x) => {
      const ug = Object.entries(x.gauges ?? {}).map(([k, v]) => `${esc(k.replace("_", " "))} ${esc(gaugeText(k, v))}`).join(" · ");
      return `<li><div class="urow"><span class="uname" title="${esc(x.name)}">${esc(x.name)}</span><span class="ucount">${esc(num(x.count))}</span></div>
        <div class="umeta">${x.route ? `<span>${esc(x.route)}</span>` : ""}<span>${ug}</span></div>
        ${(x.members ?? []).length ? `<ul class="members">${x.members.map((m) => `<li><span class="pip"></span><span class="mlabel" title="${esc(m.label ?? m.id)}">${esc(m.label ?? m.id)}</span>
          <span class="mmeta">${m.since ? `${esc(ago(m.since))}` : ""}${isNum(m.counters?.events) ? ` · ${esc(num(m.counters.events))} ev` : ""}${isNum(m.gauges?.memory) ? ` · ${esc(bytes(m.gauges.memory))}` : ""}</span></li>`).join("")}
          ${x.count > x.members.length ? `<li class="more">and ${esc(num(x.count - x.members.length))} more</li>` : ""}</ul>` : ""}</li>`;
    }).join("")}</ul></div>`;
  }
  if (hasRuntime && r.units && !r.units.length) out += `<div class="sec"><h3>Units</h3><p class="note">nothing alive inside right now</p></div>`;

  const streams = r.streams ?? [];
  if (streams.length) {
    const top = Math.max(...streams.map((x) => x.rate ?? 0), 1e-9);
    out += `<div class="sec"><h3>What happens inside <span class="h3note">per second</span></h3><ul class="paths streams">${streams.map((x) => `<li style="--c:${STREAM_COLOR[x.kind] ?? "#9aa5b8"}">
        <div class="prow"><span class="path" title="${esc(x.name)}${x.by ? ` by ${esc(x.by.name)}` : ""}"><i class="skind">${esc(x.kind)}</i> ${esc(x.name)}${x.by ? ` <i class="sby">by ${esc(x.by.name.split(".").slice(-2).join("."))}</i>` : ""}</span><span class="v">${x.rate == null ? `<span class="unk">${UNKNOWN}</span>` : esc(num(x.rate))}</span></div>
        <div class="pbar"><span style="width:${x.rate ? Math.max(2, (x.rate / top) * 100) : 0}%;background:var(--c)"></span></div>
        <div class="pmeta"><span>${isNum(x.avg_ms) ? `avg ${esc(num(x.avg_ms))} ms` : "avg -"}</span><span>${esc(num(x.count))} since start</span>${x.err_rate > 0 ? `<span class="bad">${esc(num(x.err_rate))} err/s</span>` : ""}</div>
      </li>`).join("")}</ul></div>`;
  }
  out += eventsList(r.events);
  const t = r.truncated ?? {};
  if ((t.units ?? 0) + (t.members ?? 0) + (t.streams ?? 0) > 0) out += `<p class="note">The report was cut: ${esc(num(t.units ?? 0))} units, ${esc(num(t.members ?? 0))} members, ${esc(num(t.streams ?? 0))} streams not shown.</p>`;
  return out;
}

// From the access log: how long requests took over the last five minutes.
function latency(n) {
  const l = n.latency;
  if (!l) return "";
  const cell = (k, v) => `<div class="pct"><span class="k">${k}</span><span class="v">${isNum(v) ? `${esc(num(v))} ms` : `<span class="unk">${UNKNOWN}</span>`}</span></div>`;
  return `<div class="sec"><h3>Latency <span class="h3note">${esc(num(l.count))} requests, 5 min</span></h3>
    <div class="pcts">${cell("p50", l.p50_ms)}${cell("p95", l.p95_ms)}${cell("p99", l.p99_ms)}</div></div>`;
}

// From the access log: the busiest paths of this node over the last five minutes.
function routes(n, snap) {
  const access = snap.sources?.access;
  if (n.routes == null) {
    if (!access || !(n.hosts?.length || n.via?.length)) return "";
    return `<div class="sec"><h3>Busiest paths</h3><p class="note">${access.ok ? "not read yet" : `unknown: access log source failing (${esc(access.error ?? "no error given")})`}</p></div>`;
  }
  if (!n.routes.length) return n.hosts?.length || n.via?.length ? `<div class="sec"><h3>Busiest paths</h3><p class="note">no requests in the last 5 minutes</p></div>` : "";
  const top = Math.max(...n.routes.map((r) => r.count));
  return `<div class="sec"><h3>Busiest paths <span class="h3note">5 min</span></h3><ul class="paths">${n.routes.map((r) => `<li>
      <div class="prow"><span class="path" title="${esc(r.path)}">${esc(r.path)}</span><span class="v">${esc(num(r.count))}</span></div>
      <div class="pbar"><span style="width:${Math.max(2, (r.count / top) * 100)}%"></span></div>
      <div class="pmeta"><span>${u(r.rps, num)} req/s</span><span>p95 ${isNum(r.p95_ms) ? `${esc(num(r.p95_ms))} ms` : UNKNOWN}</span>${r.errors > 0 ? `<span class="bad">${esc(num(r.errors))} 5xx</span>` : ""}</div>
    </li>`).join("")}</ul></div>`;
}

// On the Internet node: who is asking, by User-Agent class and country.
function clients(n) {
  const c = n.clients;
  if (!c) return "";
  const col = { browser: "#4cc9f0", bot: "#c77dff", tool: "#ffd166", other: "#9aa5b8" };
  const total = Object.values(c.classes).reduce((a, v) => a + v, 0);
  const bar = total > 0 ? `<div class="stack">${Object.entries(c.classes).filter(([, v]) => v > 0).map(([k, v]) => `<span style="flex:${v / total};background:${col[k] ?? "#9aa5b8"}" title="${esc(k)}"></span>`).join("")}</div>` : "";
  return `<div class="sec"><h3>Who is asking <span class="h3note">${esc(num(total))} requests, 5 min</span></h3>${bar}
    <ul class="keyed">${Object.entries(c.classes).map(([k, v]) => `<li style="--c:${col[k] ?? "#9aa5b8"}"><span class="sw"></span>${esc(k)}<span class="v">${esc(num(v))}</span></li>`).join("")}</ul>
    <h3 style="margin-top:14px">From</h3><ul class="keyed">${c.countries.map((x) => `<li>${esc(x.code === "??" ? "unknown" : x.code)}<span class="v">${esc(num(x.count))}</span></li>`).join("")}</ul></div>`;
}

function via(n) {
  if (!n.via?.length) return "";
  return `<div class="sec"><h3>Routes on other hosts</h3><ul class="keyed">${n.via.map((v) => `<li>${esc(v)}</li>`).join("")}</ul>
    <p class="note">${isNum(n.via_rps) ? `${esc(num(n.via_rps))} req/s over these routes, from the access log` : "not metered: no access log"}</p></div>`;
}

function probe(n) {
  if (n.probe == null) return "";
  const p = n.probe;
  const verdict = p.ok ? '<span class="ok">OK</span>' : '<span class="bad">FAIL</span>';
  return `<div class="sec"><h3>Probe</h3><div class="probe">${verdict}<span>${p.code == null ? "no answer" : `HTTP ${esc(p.code)}`}</span><span class="unk">${isNum(p.ms) ? `${esc(p.ms)} ms` : UNKNOWN}</span></div>
    ${p.error ? `<p class="note err" style="margin:6px 0 0">${esc(p.error)}</p>` : ""}</div>`;
}

function container(n) {
  const c = n.container;
  if (!c) return "";
  const rows = [
    ["name", u(c.name)], ["state", u(c.state)], ["docker says", u(c.status_text)], ["uptime", u(c.uptime_s, duration)],
    ["restarts", c.restarts > 0 ? `<span style="color:#ff8a80">${esc(c.restarts)}</span>` : u(c.restarts)],
    ["OOM killed", c.oom_killed ? '<span style="color:#ff8a80">yes</span>' : c.oom_killed == null ? u(null) : "no"],
    ["memory limit", c.mem_limit_bytes == null ? '<span class="unk">none</span>' : esc(bytes(c.mem_limit_bytes))],
    ["net in", u(c.net_rx_bps, bps)], ["net out", u(c.net_tx_bps, bps)],
  ];
  return `<div class="sec"><h3>Container</h3><dl class="kv">${rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("")}</dl></div>`;
}

// ---- charts ---------------------------------------------------------------

function seriesColor(key) {
  if (/cpu/.test(key)) return CPU_COLOR;
  if (/mem/.test(key)) return MEM_COLOR;
  if (/err/.test(key)) return "#ff6b6b";
  if (/rps|req/.test(key)) return "#ffd166";
  if (/disk/.test(key)) return "#61e294";
  return "#7fe0ff";
}

function drawChart(el, s, res) {
  const cv = el.querySelector("canvas");
  const vEl = el.querySelector(".v");
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const W = cv.clientWidth || 340, H = 64;
  cv.width = W * dpr; cv.height = H * dpr;
  const ctx = cv.getContext("2d");
  ctx.scale(dpr, dpr);
  const pts = s.points;
  const col = seriesColor(s.key);
  const span = res === "5s" ? 3600e3 : 86400e3;
  const tEnd = pts.length ? pts[pts.length - 1][0] : Date.now();
  const t0 = tEnd - span;
  const vals = pts.map((p) => p[1]).filter(isNum);
  const max = vals.length ? Math.max(...vals) : 0;
  const top = max > 0 ? max * 1.15 : 1;
  const X = (t) => ((t - t0) / span) * W;
  const Y = (v) => H - 4 - (v / top) * (H - 14);
  const fmt = (v) => withUnit(v, s.unit === "bytes" || s.unit === "B/s" ? s.unit : s.unit);

  const draw = (hoverX) => {
    ctx.clearRect(0, 0, W, H);
    // gaps: where the value is unknown, hatch the floor
    ctx.fillStyle = "rgba(139,147,167,0.18)";
    for (let i = 0; i < pts.length; i++) if (pts[i][1] == null) {
      const x0 = X(pts[i][0]), x1 = i + 1 < pts.length ? X(pts[i + 1][0]) : W;
      ctx.fillRect(x0, H - 10, Math.max(1, x1 - x0), 10);
    }
    // area + line, broken at nulls
    let run = [];
    const flush = () => {
      if (run.length > 1) {
        ctx.beginPath(); ctx.moveTo(run[0][0], H - 4);
        for (const [x, y] of run) ctx.lineTo(x, y);
        ctx.lineTo(run[run.length - 1][0], H - 4); ctx.closePath();
        ctx.fillStyle = col + "33"; ctx.fill();
        ctx.beginPath(); run.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
        ctx.strokeStyle = col; ctx.lineWidth = 1.4; ctx.stroke();
      } else if (run.length === 1) { ctx.fillStyle = col; ctx.fillRect(run[0][0] - 1, run[0][1] - 1, 2, 2); }
      run = [];
    };
    for (const [t, v] of pts) { if (v == null) flush(); else run.push([X(t), Y(v)]); }
    flush();
    ctx.fillStyle = "rgba(200,206,220,0.55)"; ctx.font = "10px ui-monospace, Menlo, monospace"; ctx.textBaseline = "top";
    ctx.fillText(`max ${vals.length ? fmt(max) : UNKNOWN}`, 4, 2);
    ctx.textAlign = "right"; ctx.fillText(res === "5s" ? "1 h" : "24 h", W - 4, 2); ctx.textAlign = "left";
    let shown = pts.length ? pts[pts.length - 1] : null;
    if (hoverX != null && pts.length) {
      const t = t0 + (hoverX / W) * span;
      let best = pts[0];
      for (const p of pts) if (Math.abs(p[0] - t) < Math.abs(best[0] - t)) best = p;
      shown = best;
      ctx.strokeStyle = "rgba(255,255,255,0.4)"; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(X(best[0]), 0); ctx.lineTo(X(best[0]), H); ctx.stroke();
    }
    vEl.innerHTML = shown == null ? `<span class="unk">${UNKNOWN}</span>`
      : `${shown[1] == null ? `<span class="unk">${UNKNOWN}</span>` : esc(fmt(shown[1]))}${hoverX != null ? ` <span class="unk">at ${esc(utc(new Date(shown[0])))}</span>` : ""}`;
  };
  draw(null);
  cv.addEventListener("pointermove", (e) => draw(e.offsetX));
  cv.addEventListener("pointerleave", () => draw(null));
}

export { num, bytes };
