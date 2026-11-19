// The inspector: bottom sheet on a phone, side panel on a desktop.

import { num, bytes, bps, withUnit, duration, esc, isNum, UNKNOWN, utc } from "./fmt.js";
import { headlineText } from "./overlay.js";
import { itemColor, HOLD_COLORS, CPU_COLOR, MEM_COLOR, STATUS_COLOR } from "./render.js";
import { fetchHistory } from "./live.js";

const $ = (id) => document.getElementById(id);
const u = (v, f = (x) => x) => (v == null ? `<span class="unk">${UNKNOWN}</span>` : esc(f(v)));

export class Inspector {
  constructor({ onClose, onNavigate }) {
    this.el = $("inspector");
    this.body = $("inspector-body");
    this.onClose = onClose;
    this.onNavigate = onNavigate;
    this.id = null;
    this.res = "5s";
    this.hist = null;
    this.histErr = null;
    this.histTimer = null;
    $("inspector-close").addEventListener("click", () => this.close());
    this.body.innerHTML = '<div class="live"></div><div class="sec hist"></div>';
    this.live = this.body.querySelector(".live");
    this.histEl = this.body.querySelector(".hist");
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

  show(id, snap) {
    const changed = id !== this.id;
    this.id = id;
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
    clearTimeout(this.histTimer);
    this.onClose();
  }

  update(snap) {
    if (!this.id) return;
    this.snap = snap;
    const n = snap.nodes.find((x) => x.id === this.id);
    if (!n) {
      this.live.innerHTML = `<div class="ins-head"><h2>${esc(this.id)}</h2></div><p class="note err">This node is no longer in the snapshot.</p>`;
      return;
    }
    this.live.innerHTML = [head(n), facts(n), holds(n), power(n, snap), drawnBy(n, snap), flows(n, snap), hostsTable(n), via(n), probe(n), container(n)].join("");
  }

  async loadHistory() {
    clearTimeout(this.histTimer);
    const id = this.id, res = this.res;
    if (!id) return;
    try {
      const h = await fetchHistory(id, res);
      if (id !== this.id || res !== this.res) return;
      this.hist = h; this.histErr = null;
    } catch (err) {
      if (id !== this.id) return;
      this.histErr = err.message;
    }
    this.renderHistory();
    this.histTimer = setTimeout(() => this.loadHistory(), res === "5s" ? 15000 : 60000);
  }

  renderHistory() {
    const seg = `<span class="seg" role="group" aria-label="History range">
      <button data-res="5s" aria-pressed="${this.res === "5s"}">1 h</button><button data-res="1m" aria-pressed="${this.res === "1m"}">24 h</button></span>`;
    let inner;
    if (this.histErr) inner = `<p class="note err">${esc(this.histErr)}</p>`;
    else if (!this.hist) inner = '<p class="note">Loading…</p>';
    else if (!this.hist.series.length) inner = '<p class="note">No series for this node.</p>';
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
  const sub = [n.kind, n.container?.name ?? null, n.platform ? `on ${n.platform}` : "not in the topology"].filter(Boolean).join(" · ");
  return `<div class="ins-head">
    <h2>${esc(n.label)}</h2>
    <div class="sub">${esc(sub)}</div>
    <div class="status-pill st-${esc(n.status)}"><span class="lamp ${esc(n.status)}" style="background:${n.status === "unknown" ? "transparent" : STATUS_COLOR[n.status] ?? "#888"}"></span>${esc(n.status)}<span class="unk" style="font-weight:500;margin-left:6px">${esc(headlineText(n.headline))}</span></div>
    ${n.reason ? `<div class="reason">${esc(n.reason)}</div>` : ""}
  </div>`;
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
  return `<div class="sec"><h3>Holds</h3>${bar}<ul class="keyed">${list.map((h) => `<li style="--c:${color(idx.get(h.label))}"><span class="sw"></span>${esc(h.label)}<span class="v">${u(h.bytes, bytes)}</span></li>`).join("")}</ul></div>`;
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

function hostsTable(n) {
  if (!n.hosts?.length) return "";
  const ms = (v) => (isNum(v) ? `${num(v)} ms` : null);
  return `<div class="sec"><h3>Hosts</h3><table class="hosts"><thead><tr><th>host</th><th>req/s</th><th>err/s</th><th>avg</th></tr></thead><tbody>
    ${n.hosts.map((h) => `<tr><td>${esc(h.host)}</td><td>${u(h.rps, num)}</td><td>${u(h.err_rps, num)}</td><td>${u(ms(h.avg_ms))}</td></tr>`).join("")}
  </tbody></table></div>`;
}

function via(n) {
  if (!n.via?.length) return "";
  return `<div class="sec"><h3>Routes on other hosts</h3><ul class="keyed">${n.via.map((v) => `<li>${esc(v)}<span class="v unk">not metered</span></li>`).join("")}</ul></div>`;
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
