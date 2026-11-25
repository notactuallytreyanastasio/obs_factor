// The board's Oban tab: the observer's own background jobs (ObsFactor.Jobs),
// live from channel "jobs" (ObsFactorWeb.JobsChannel) while the board is open.
//
//   a strip of states: what waits now (available, scheduled, executing,
//   retryable) and what finished in the last 24 h (completed, discarded,
//   cancelled)
//   the last hour, a bar a minute: jobs completed, jobs that failed for
//   good, and attempts that errored (a retried job is one per attempt)
//   queues: running of the limit, waiting, paused; an operator pauses and
//   resumes them
//   cron: each entry, when it runs next and how its last run went; an
//   operator runs one now
//   workers: the last 24 h per worker, run time p50/p95 and wait p95
//   jobs: the newest 60, filtered by state, queue (click a queue) or worker
//   (click a worker); a click opens one beside the list with its args, its
//   timings and every error, and an operator retries, cancels or deletes it
//
// Jobs are not on the tape: a replayed moment shows them as they are now.

import * as bus from "./bus.js";
import { esc, num } from "./fmt.js";
import { isOperator } from "./identity.js";

const TOPIC = "jobs";
const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const WAITING = ["available", "scheduled", "executing", "retryable"];
const DONE = ["completed", "discarded", "cancelled"];
const STATES = [...WAITING, ...DONE];
const short = (w) => String(w ?? "").replace(/^ObsFactor\.Jobs\./, "").replace(/^Elixir\./, "");

function ms(v) {
  if (!isNum(v)) return "–";
  if (v < 1) return "<1 ms";
  if (v < 1000) return `${Math.round(v)} ms`;
  if (v < 60e3) return `${(v / 1000).toFixed(v < 10e3 ? 1 : 0)} s`;
  if (v < 3600e3) return `${Math.floor(v / 60e3)}m ${Math.round((v % 60e3) / 1000)}s`;
  return `${Math.floor(v / 3600e3)}h ${Math.floor((v % 3600e3) / 60e3)}m`;
}

// "12s ago", "in 40s"
function rel(t, now) {
  if (!isNum(t)) return "–";
  const d = t - now, a = Math.abs(d);
  const s = a < 60e3 ? `${Math.round(a / 1000)}s` : a < 3600e3 ? `${Math.floor(a / 60e3)}m` : a < 86400e3 ? `${Math.floor(a / 3600e3)}h` : `${Math.floor(a / 86400e3)}d`;
  return d > 0 ? `in ${s}` : `${s} ago`;
}

const hms = (t) => (isNum(t) ? new Date(t).toISOString().slice(11, 19) : "–");

export class ObanTab {
  constructor(board) {
    this.b = board;
    this.v = null; // the view (ObsFactor.Jobs.View)
    this.error = null;
    this.unsub = null;
    this.filter = { state: null, queue: null, worker: null };
    this.sel = null; // the job id open beside the list
    this.job = null; // that job, whole
    this.msg = "";
    this.at = Date.now(); // when the view arrived: "ago" is measured from it
  }

  // ---- the feed ------------------------------------------------------------------

  // joined while the board is open (the tab's label counts), left when it closes
  sync(active) {
    if (active && !this.unsub) {
      this.unsub = bus.subscribe(TOPIC, (ev, p) => { if (ev === "view") this.take(p); }, {
        params: () => ({ filter: this.filter }),
        onJoin: (p) => this.take(p),
        onError: (why) => { this.error = String(why); this.redraw(); },
      });
    } else if (!active && this.unsub) {
      this.unsub(); this.unsub = null;
    }
  }

  idle() { this.sync(false); }

  take(p) {
    if (!p) return;
    this.error = p.error ?? null;
    if (!p.error || !this.v) this.v = p;
    this.at = Date.now();
    if (this.sel && this.v?.jobs?.some((j) => j.id === this.sel && j.state !== this.job?.state)) this.load(this.sel);
    this.redraw();
  }

  redraw() { if (this.b.open && this.b.tab === "oban") this.b.renderMonitor(false); }

  count() { const s = this.v?.states ?? {}; return WAITING.reduce((n, k) => n + (s[k] ?? 0), 0); }

  // something failed in the last 24 h, or waits to be retried
  failing() { const s = this.v?.states ?? {}; return (s.discarded ?? 0) + (s.retryable ?? 0) > 0; }

  label() { return `Oban <b>${this.v ? num(this.count()) : "…"}${this.failing() ? "!" : ""}</b>`; }

  // ---- clicks ------------------------------------------------------------------------

  onClick(e) {
    const f = e.target.closest("[data-ob-f]");
    if (f) {
      const [k, v] = JSON.parse(f.dataset.obF);
      this.setFilter(k === "all" ? { state: null, queue: null, worker: null } : { ...this.filter, [k]: this.filter[k] === v ? null : v });
      return true;
    }
    const row = e.target.closest("[data-ob-job]");
    if (row && !e.target.closest("button")) {
      const id = Number(row.dataset.obJob);
      this.sel = this.sel === id ? null : id; this.job = null; this.msg = "";
      if (this.sel) this.load(id);
      this.b.renderMonitor();
      return true;
    }
    if (e.target.closest("[data-ob-close]")) { this.sel = null; this.job = null; this.b.renderMonitor(); return true; }
    const act = e.target.closest("[data-ob-act]");
    if (act) { this.act(act.dataset.obAct, JSON.parse(act.dataset.obArg)); return true; }
    return false;
  }

  setFilter(f) {
    this.filter = f;
    this.b.renderMonitor();
    bus.push(TOPIC, "filter", f)
      .then((r) => { if (this.v) this.v = { ...this.v, jobs: r.jobs, filter: r.filter }; this.redraw(); })
      .catch((x) => { this.msg = x.message; this.redraw(); });
  }

  load(id) {
    bus.push(TOPIC, "job", { id })
      .then((r) => { if (this.sel === id) { this.job = r.job; this.paintSide(); } })
      .catch((x) => { if (this.sel === id) { this.job = { error: x.message }; this.paintSide(); } });
  }

  act(what, arg) {
    if (what === "delete" && !confirm(`Delete job ${arg.id}? Its row and its errors go.`)) return;
    this.msg = `${what}…`; this.paintSide(); this.redraw();
    bus.push(TOPIC, what, arg)
      .then((r) => {
        this.msg = r.ok;
        if (what === "delete" && this.sel === arg.id) { this.sel = null; this.job = null; }
        else if (arg.id && this.sel === arg.id) this.load(arg.id);
        this.b.renderMonitor();
      })
      .catch((x) => { this.msg = x.message; this.paintSide(); this.redraw(); });
  }

  // ---- drawing -----------------------------------------------------------------------

  tab() {
    this.sync(true);
    const v = this.v;
    if (!v) return `<p class="bd-empty">${this.error ? esc(this.error) : "reading Oban…"}</p>`;
    if (this.error && !(v.queues ?? []).length) return `<p class="bd-empty">${esc(this.error)}</p><p class="bd-foot">Oban runs in the observer with its objectives database (OBJECTIVES_PG_URL): scheduled writeups, hourly rollups, alert and writeup webhooks.</p>`;
    const now = v.now + (Date.now() - this.at);
    const err = this.error ? `<p class="slo-note">${esc(this.error)} (showing the last view)</p>` : "";
    const replay = this.b.api.timeline?.replaying ? `<p class="slo-note">Jobs are not on the tape: this is now, not the replayed moment.</p>` : "";
    const side = this.sel ? `<div class="ps-side ob-side" id="ob-side">${this.sideHtml(now)}</div>` : "";
    return `<div class="ob">${err}${replay}${this.strip(v)}${this.hour(v)}
      <div class="ob-grid">${this.queues(v)}${this.cron(v, now)}</div>
      ${this.workers(v, now)}
      <div class="ps-wrap ob-wrap"><div class="ob-jobs">${this.jobs(v, now)}</div>${side}</div>
      <p class="bd-foot">Oban ${isOperator() ? "" : "(read only: retrying, cancelling, pausing and running are an operator's) "}on the observer's objectives database: finished jobs are kept 7 days (Pruner), a job left executing by a restart is rescued after 30 minutes (Lifeline). Run time is attempted to completed; wait is scheduled to attempted.</p></div>`;
  }

  strip(v) {
    const s = v.states ?? {};
    const cell = (k) => {
      const n = s[k] ?? 0;
      const cls = n && (k === "retryable" || k === "discarded") ? " bad" : n && k === "executing" ? " on" : "";
      return `<button type="button" class="ob-st s-${k}${cls}${this.filter.state === k ? " sel" : ""}" data-ob-f='${esc(JSON.stringify(["state", k]))}'><i>${esc(k)}</i><b>${num(n)}</b></button>`;
    };
    return `<div class="ob-strip"><span class="ob-lab">now</span>${WAITING.map(cell).join("")}<span class="ob-lab">24 h</span>${DONE.map(cell).join("")}</div>`;
  }

  // the last hour, a bar a minute: completed up, failed (red) and errored attempts (amber) down
  hour(v) {
    const m = v.minutes ?? [];
    if (!m.length) return "";
    const W = 600, H = 54, mid = 34, bw = W / m.length;
    const up = Math.max(1, ...m.map((r) => r[1])), down = Math.max(1, ...m.map((r) => r[2] + r[3]));
    const bars = m.map(([t, c, f, e], i) => {
      const x = (i * bw).toFixed(1), w = Math.max(1, bw - 1).toFixed(1);
      const hc = (c / up) * (mid - 2), hf = (f / down) * (H - mid - 2), he = (e / down) * (H - mid - 2);
      return `<g><title>${hms(t)} UTC · ${c} completed · ${f} failed · ${e} errored attempt${e === 1 ? "" : "s"}</title>
        ${c ? `<rect class="c" x="${x}" y="${(mid - hc).toFixed(1)}" width="${w}" height="${hc.toFixed(1)}"/>` : ""}
        ${f ? `<rect class="f" x="${x}" y="${mid + 1}" width="${w}" height="${hf.toFixed(1)}"/>` : ""}
        ${e ? `<rect class="e" x="${x}" y="${(mid + 1 + hf).toFixed(1)}" width="${w}" height="${Math.max(0, he - hf).toFixed(1)}"/>` : ""}</g>`;
    }).join("");
    const sum = (i) => m.reduce((n, r) => n + r[i], 0);
    return `<div class="ob-hour"><svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="jobs in the last hour">${bars}<line x1="0" x2="${W}" y1="${mid + 0.5}" y2="${mid + 0.5}"/></svg>
      <div class="ob-hour-l"><span><b class="c">${num(sum(1))}</b> completed</span><span><b class="f">${num(sum(2))}</b> failed</span><span><b class="e">${num(sum(3))}</b> errored attempts</span><span class="dim">last 60 min, a bar a minute</span></div></div>`;
  }

  queues(v) {
    const op = isOperator();
    const rows = (v.queues ?? []).map((q) => {
      const lim = q.limit ?? 0, run = Math.max(q.running ?? 0, q.executing ?? 0);
      const w = lim ? Math.min(100, (run / lim) * 100) : 0;
      const btn = q.configured ? `<button type="button" class="slo-btn" data-ob-act="${q.paused ? "resume" : "pause"}" data-ob-arg='${esc(JSON.stringify({ queue: q.name }))}'${op ? "" : " disabled title=\"an operator's\""}>${q.paused ? "resume" : "pause"}</button>` : `<span class="dim">not here</span>`;
      return `<tr class="${q.paused ? "warn" : ""}"><td class="nm"><span class="ob-link${this.filter.queue === q.name ? " sel" : ""}" data-ob-f='${esc(JSON.stringify(["queue", q.name]))}'>${esc(q.name)}</span>${q.paused ? ` <span class="slo-flag slow">PAUSED</span>` : ""}</td>
        <td><span class="slo-bar ${run >= lim && lim ? "low" : "ok"}"><i style="width:${w}%"></i></span> ${num(run)}/${lim ? num(lim) : "–"}</td>
        <td class="r">${num(q.available)}</td><td class="r">${num(q.scheduled)}</td><td class="r${q.retryable ? " bad" : ""}">${num(q.retryable)}</td>
        <td class="r">${num(q.completed)}</td><td class="r${q.discarded ? " bad" : ""}">${num(q.discarded)}</td><td>${btn}</td></tr>`;
    }).join("");
    return `<div><h4>Queues</h4><div class="slo-scroll"><table><thead><tr><th>queue</th><th>running</th><th class="r">avail</th><th class="r">sched</th><th class="r">retry</th><th class="r">done 24h</th><th class="r">failed</th><th></th></tr></thead><tbody>${rows}</tbody></table></div></div>`;
  }

  cron(v, now) {
    const op = isOperator();
    const rows = (v.cron ?? []).map((c) => {
      const last = c.last ? `<span class="ob-s s-${esc(c.last.state)}">${esc(c.last.state)}</span> ${rel(c.last.at, now)}` : `<span class="dim">never</span>`;
      return `<tr><td class="nm"><code>${esc(c.expr)}</code></td><td class="nm"><span class="ob-link" data-ob-f='${esc(JSON.stringify(["worker", c.worker]))}'>${esc(short(c.worker))}</span></td>
        <td class="r">${rel(c.next_at, now)}</td><td>${last}</td>
        <td><button type="button" class="slo-btn" data-ob-act="run_cron" data-ob-arg='${esc(JSON.stringify({ worker: c.worker }))}'${op ? "" : " disabled title=\"an operator's\""}>run now</button></td></tr>`;
    }).join("");
    return `<div><h4>Cron</h4><div class="slo-scroll"><table><thead><tr><th>schedule</th><th>worker</th><th class="r">next</th><th>last</th><th></th></tr></thead><tbody>${rows}</tbody></table></div></div>`;
  }

  workers(v, now) {
    const rows = (v.workers ?? []).map((w) => `<tr><td class="nm"><span class="ob-link${this.filter.worker === w.worker ? " sel" : ""}" data-ob-f='${esc(JSON.stringify(["worker", w.worker]))}' title="${esc(w.worker)}">${esc(short(w.worker))}</span></td><td>${esc(w.queue)}</td>
      <td class="r">${num(w.completed)}</td><td class="r${w.discarded ? " bad" : ""}">${num(w.discarded)}</td><td class="r">${num(w.cancelled)}</td><td class="r${w.retried ? " warn" : ""}">${num(w.retried)}</td><td class="r">${num(w.pending)}</td>
      <td class="r">${ms(w.p50)}</td><td class="r">${ms(w.p95)}</td><td class="r">${ms(w.wait_p95)}</td>
      <td>${w.last ? `<span class="ob-s s-${esc(w.last.state)}">${esc(w.last.state)}</span> ${rel(w.last.at, now)}` : "–"}</td></tr>`).join("");
    if (!rows) return `<h4>Workers</h4><p class="bd-empty">No job in the last 24 h.</p>`;
    return `<h4>Workers <span class="dim">last 24 h</span></h4><div class="slo-scroll"><table><thead><tr><th>worker</th><th>queue</th><th class="r">done</th><th class="r">failed</th><th class="r">cancelled</th><th class="r">retried</th><th class="r">waiting</th><th class="r">p50</th><th class="r">p95</th><th class="r">wait p95</th><th>last</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  }

  jobs(v, now) {
    const f = this.filter;
    const on = [["state", f.state], ["queue", f.queue], ["worker", f.worker]].filter(([, x]) => x);
    const named = on.filter(([k]) => k !== "state"); // the state is lit among the chips already
    const chips = STATES.map((s) => `<button type="button" class="bd-chip${f.state === s ? " on" : ""}" data-ob-f='${esc(JSON.stringify(["state", s]))}'>${esc(s)}</button>`).join("");
    const active = named.map(([k, x]) => `<button type="button" class="bd-chip on" data-ob-f='${esc(JSON.stringify([k, x]))}' title="remove">${esc(k)}: ${esc(short(x))} ×</button>`).join("");
    const all = on.length ? `<button type="button" class="bd-chip" data-ob-f='["all",null]'>all</button>` : "";
    const rows = (v.jobs ?? []).map((j) => {
      const when = j.finished_at ?? j.attempted_at ?? j.scheduled_at;
      return `<tr class="ob-row${j.id === this.sel ? " on" : ""}" data-ob-job="${j.id}"><td class="r">${j.id}</td><td><span class="ob-s s-${esc(j.state)}">${esc(j.state)}</span></td><td class="nm" title="${esc(j.worker)}">${esc(short(j.worker))}</td><td>${esc(j.queue)}</td>
        <td class="r${j.attempt > 1 ? " warn" : ""}">${j.attempt}/${j.max_attempts}</td><td class="r" title="${hms(when)} UTC">${rel(when, now)}</td>
        <td class="ob-args" title="${esc(j.args)}">${esc(j.args)}</td><td class="ob-err" title="${esc(j.error ?? "")}">${esc(j.error ?? "")}</td></tr>`;
    }).join("");
    const body = rows
      ? `<div class="slo-scroll"><table><thead><tr><th class="r">id</th><th>state</th><th>worker</th><th>queue</th><th class="r">try</th><th class="r">when</th><th>args</th><th>last error</th></tr></thead><tbody>${rows}</tbody></table></div>`
      : `<p class="bd-empty">No job ${on.length ? "matches" : "yet"}.</p>`;
    return `<h4>Jobs <span class="dim">newest ${num((v.jobs ?? []).length)}</span></h4><div class="ob-chips">${chips}${active}${all}</div>${this.msg && !this.sel ? `<p class="slo-msg">${esc(this.msg)}</p>` : ""}${body}`;
  }

  // redraw the side panel alone (a job arriving must not redraw the board)
  paintSide() {
    const el = this.b.el.querySelector("#ob-side");
    if (el) el.innerHTML = this.sideHtml(this.v ? this.v.now + (Date.now() - this.at) : Date.now());
  }

  sideHtml(now) {
    const head = `<div class="ps-h"><b>job ${this.sel}</b><button type="button" class="fi-x" data-ob-close aria-label="Close">×</button></div>`;
    const j = this.job;
    if (!j) return `${head}<p class="bd-empty">reading…</p>`;
    if (j.error && !j.id) return `${head}<p class="bd-empty">${esc(j.error)}</p>`;
    const op = isOperator();
    const can = { retry: ["retryable", "discarded", "cancelled", "completed", "scheduled"].includes(j.state), cancel: ["available", "scheduled", "executing", "retryable"].includes(j.state), delete: j.state !== "executing" };
    const btn = (what, label) => `<button type="button" class="slo-btn" data-ob-act="${what}" data-ob-arg='${esc(JSON.stringify({ id: j.id }))}'${op && can[what] ? "" : ` disabled title="${op ? `not while ${esc(j.state)}` : "an operator's"}"`}>${label}</button>`;
    const fin = j.completed_at ?? j.discarded_at ?? j.cancelled_at;
    const row = (k, v) => `<tr><td class="nm">${k}</td><td>${v}</td></tr>`;
    const at = (t) => (isNum(t) ? `${hms(t)} UTC <span class="dim">${rel(t, now)}</span>` : "–");
    const errors = (j.errors ?? []).slice().reverse().map((e) => `<div class="ob-e"><div class="dim">attempt ${e.attempt} · ${esc(String(e.at ?? "").slice(11, 19))} UTC</div><pre>${esc(e.error)}</pre></div>`).join("");
    return `${head}<p><span class="ob-s s-${esc(j.state)}">${esc(j.state)}</span> <b title="${esc(j.worker)}">${esc(short(j.worker))}</b> <span class="dim">on ${esc(j.queue)} · attempt ${j.attempt} of ${j.max_attempts}</span></p>
      <div class="ob-acts">${btn("retry", "retry")}${btn("cancel", "cancel")}${btn("delete", "delete")}${this.msg ? ` <span class="slo-msg">${esc(this.msg)}</span>` : ""}</div>
      <table class="ps-proc">${row("inserted", at(j.inserted_at))}${row("scheduled", at(j.scheduled_at))}${row("attempted", at(j.attempted_at))}${row(j.completed_at ? "completed" : j.discarded_at ? "discarded" : j.cancelled_at ? "cancelled" : "finished", at(fin))}
        ${row("waited", ms(isNum(j.attempted_at) && isNum(j.scheduled_at) && j.attempted_at >= j.scheduled_at ? j.attempted_at - j.scheduled_at : null))}${row("ran", ms(isNum(fin) && isNum(j.attempted_at) ? fin - j.attempted_at : null))}
        ${row("by", esc((j.attempted_by ?? []).join(" ") || "–"))}${(j.tags ?? []).length ? row("tags", esc(j.tags.join(", "))) : ""}</table>
      <h4>args</h4><pre class="ob-json">${esc(JSON.stringify(j.args, null, 2))}</pre>
      ${Object.keys(j.meta ?? {}).length ? `<h4>meta</h4><pre class="ob-json">${esc(JSON.stringify(j.meta, null, 2))}</pre>` : ""}
      <h4>errors <span class="dim">${(j.errors ?? []).length}</span></h4>${errors || `<p class="bd-empty">none</p>`}`;
  }
}
