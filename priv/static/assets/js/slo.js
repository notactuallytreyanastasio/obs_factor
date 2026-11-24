// The board's SLO tab: error budgets per app (ObsFactor.SLOs, topic "slo").
//
// One block per target: the SLI over its rolling window (7 or 30 days), the
// budget left as a bar, the burn rate over 1 h and 6 h against the window's
// thresholds (14.4x and 6x for 30 days, 3.36x and 1.4x for 7), and FAST or
// SLOW when a flag is up. Below them a form sets or changes a target.
//
// The numbers are live: the server computes them once a minute over the
// tape up to now and pushes `status`. A replayed moment on the timeline does
// not replay them (the tab says so).

import * as bus from "./bus.js";
import { esc, num } from "./fmt.js";

const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const pct = (v, d = 3) => (isNum(v) ? `${(v * 100).toFixed(d).replace(/\.?0+$/, "")}%` : "–");
const x = (v) => (isNum(v) ? `${v.toFixed(1)}x` : "–");
function span(ms) { const h = Math.floor(ms / 3600e3); return h >= 48 ? `${Math.floor(h / 24)}d ${h % 24}h` : h >= 1 ? `${h}h ${Math.floor((ms % 3600e3) / 60e3)}m` : `${Math.floor(ms / 60e3)}m`; }

export class SLOs {
  constructor(board) {
    this.board = board;
    this.reports = [];
    this.thresholds = { 7: { fast: 3.36, slow: 1.4 }, 30: { fast: 14.4, slow: 6 } };
    this.error = null;
    this.editing = null; // the node whose target is in the form
    this.msg = "";
    board.el.addEventListener("click", (e) => this.onClick(e));
    board.el.addEventListener("submit", (e) => this.onSubmit(e));
    bus.subscribe("slo", (ev, p) => { if (ev === "status") this.set(p.reports); }, {
      onJoin: (r) => { if (r.thresholds) this.thresholds = r.thresholds; this.error = r.error ?? null; this.set(r.reports ?? []); },
      onError: (why) => { this.error = String(why); this.redraw(); },
    });
  }

  set(reports) { this.reports = reports; this.redraw(); }

  // a push must not pull the form out from under someone typing in it:
  // renderMonitor(false) leaves the board alone then
  redraw() { if (this.board.open && this.board.tab === "slo") this.board.renderMonitor(false); }

  count() { return this.reports.length; }
  burning() { return this.reports.filter((r) => [r.availability, r.latency].some((o) => o && (o.fast || o.slow))).length; }

  tab() {
    const head = this.error ? `<p class="bd-empty">${esc(this.error)}</p>` : "";
    const list = this.reports.length
      ? this.reports.map((r) => this.block(r)).join("")
      : `<p class="bd-empty">No error budget is set. Set one below: a share of requests that must not be a 5xx, over 7 or 30 days.</p>`;
    const replay = this.board.api.timeline?.replaying ? `<p class="slo-note">These are live, computed up to now: a replayed moment does not replay them.</p>` : "";
    return `<div class="slo">${head}${replay}${list}${this.form()}
      <p class="bd-foot">SLI: requests without a 5xx (and, for latency, requests served while the app's p95 was under its limit), from the proxy's per-host counts on the tape. Burn 1x spends the budget exactly over the window. A flag needs the long and the short window over the threshold (1 h and 5 m, 6 h and 30 m) and at least 20 requests. Its start is an slo_burn item on the wire.</p></div>`;
  }

  block(r) {
    const objs = [["availability", r.availability, `${pct(r.target.availability)} without a 5xx`], ["latency", r.latency, r.latency ? `${pct(r.target.latency_target)} with p95 ≤ ${num(r.target.latency_ms)} ms` : ""]].filter(([, o]) => o);
    const rows = objs.map(([name, o, what]) => {
      const left = o.budget_left_pct;
      const w = isNum(left) ? Math.max(0, Math.min(100, left)) : 0;
      const lvl = !isNum(left) ? "na" : left <= 0 ? "out" : left < 25 ? "low" : left < 50 ? "mid" : "ok";
      const flag = (o.fast ? `<span class="slo-flag fast">FAST</span>` : "") + (o.slow ? `<span class="slo-flag slow">SLOW</span>` : "");
      const burn = (k, t) => `<span class="${isNum(o.burn[k]) && o.burn[k] >= t ? "bad" : ""}" title="threshold ${t}x">${x(o.burn[k])}</span>`;
      return `<tr class="${o.fast ? "alert" : o.slow ? "warn" : ""}"><td class="nm">${esc(name)}<br><span class="dim">${esc(what)}</span></td>
        <td class="r">${isNum(o.sli) ? pct(o.sli) : `<span class="dim">no requests</span>`}</td>
        <td class="slo-bud"><span class="slo-bar ${lvl}"><i style="width:${w}%"></i></span> ${isNum(left) ? `${left}%` : "–"}</td>
        <td class="r">${burn("1h", r.thresholds.fast)}</td><td class="r">${burn("6h", r.thresholds.slow)}</td><td>${flag}</td><td class="r">${num(o.requests)}</td></tr>`;
    }).join("");
    const notes = [r.coverage?.note, r.note].filter(Boolean).map((n) => `<p class="slo-note">${esc(n)}</p>`).join("");
    return `<div class="slo-app" data-slo-node="${esc(r.node)}"><h4><span class="slo-go" data-slo-go="${esc(r.node)}">${esc(r.label)}</span> <span class="dim">${r.window_days}-day window · flags at ${r.thresholds.fast}x / ${r.thresholds.slow}x${r.by ? ` · set by ${esc(r.by)}` : ""}</span>
      <button type="button" class="slo-btn" data-slo-act="edit">edit</button><button type="button" class="slo-btn" data-slo-act="del">remove</button></h4>
      <div class="slo-scroll"><table><thead><tr><th>objective</th><th class="r">sli</th><th>budget left</th><th class="r">burn 1h</th><th class="r">burn 6h</th><th></th><th class="r">requests</th></tr></thead><tbody>${rows}</tbody></table></div>${notes}</div>`;
  }

  form() {
    const cur = this.reports.find((r) => r.node === this.editing);
    const t = cur?.target ?? {};
    const nodes = (this.board.shown?.nodes ?? []).filter((n) => (n.hosts ?? []).length && n.kind !== "proxy");
    const opts = nodes.map((n) => `<option value="${esc(n.id)}">${esc(n.label ?? n.id)}</option>`).join("");
    const days = cur?.window_days ?? 30;
    return `<form class="slo-form" data-form="slo"><h4>${cur ? `Change ${esc(cur.label)}'s target` : "Set a target"}</h4>
      <label>app <input name="node" list="slo-nodes" required maxlength="80" value="${esc(cur?.node ?? "")}" ${cur ? "readonly" : ""} placeholder="node id"><datalist id="slo-nodes">${opts}</datalist></label>
      <label>availability <input name="availability" type="number" step="0.0001" min="0.5" max="0.9999" required value="${t.availability ?? 0.995}"></label>
      <label>window <select name="window_days"><option value="30"${days === 30 ? " selected" : ""}>30 days</option><option value="7"${days === 7 ? " selected" : ""}>7 days</option></select></label>
      <label>p95 under <input name="latency_ms" type="number" step="1" min="1" placeholder="ms (optional)" value="${t.latency_ms ?? ""}"></label>
      <label>for <input name="latency_target" type="number" step="0.001" min="0.5" max="0.999" placeholder="0.99" value="${t.latency_target ?? ""}"></label>
      <button type="submit" class="slo-btn on">${cur ? "Save" : "Add"}</button>${cur ? `<button type="button" class="slo-btn" data-slo-act="cancel">cancel</button>` : ""}
      ${this.msg ? `<span class="slo-msg">${esc(this.msg)}</span>` : ""}</form>`;
  }

  onClick(e) {
    if (this.board.tab !== "slo") return;
    const go = e.target.closest("[data-slo-go]");
    if (go) return this.board.api.go(go.dataset.sloGo);
    const act = e.target.closest("[data-slo-act]")?.dataset.sloAct;
    if (!act) return;
    const node = e.target.closest("[data-slo-node]")?.dataset.sloNode;
    if (act === "edit") { this.editing = node; this.msg = ""; this.board.renderMonitor(); }
    else if (act === "cancel") { this.editing = null; this.msg = ""; this.board.renderMonitor(); }
    else if (act === "del" && window.confirm(`Remove the error budget of ${node} for everyone?`)) {
      bus.push("slo", "delete", { node }).then(() => { if (this.editing === node) this.editing = null; }).catch((x) => window.alert(x.message));
    }
  }

  onSubmit(e) {
    const f = e.target;
    if (f.dataset.form !== "slo") return;
    e.preventDefault();
    const v = (n) => f.elements[n].value.trim();
    const n = (s) => (s === "" ? null : Number(s));
    const body = { node: v("node"), availability: n(v("availability")), window_days: Number(v("window_days")), latency_ms: n(v("latency_ms")), latency_target: n(v("latency_target")), by: this.board.api.who?.() || null };
    bus.push("slo", "save", body)
      .then(() => { this.editing = null; this.msg = `saved ${body.node}`; this.board.renderMonitor(); })
      .catch((x) => { this.msg = x.message; this.board.renderMonitor(); });
  }
}
