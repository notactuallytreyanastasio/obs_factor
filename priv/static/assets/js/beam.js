// "Under the hood": the observer's own BEAM, from the feed
// observer:observer:-:beam on the page's socket (ObsFactor.Beam.report/1,
// fetched every 2 s on the server while anyone has the panel open, one
// fetch however many do). The VM it runs on, the processes under
// ObsFactor.Supervisor (one collector per source), the ETS tables the
// snapshot is built from, and its last 500 log events, filtered by level
// here. Nothing here is drawn from the snapshot.

import { num, bytes, duration, esc, utc, UNKNOWN } from "./fmt.js";
import * as bus from "./bus.js";

const TOPIC = "observer:observer:-:beam";
const RANK = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"];

const $ = (id) => document.getElementById(id);
const LEVELS = ["debug", "info", "warning", "error"];
const MEM_PARTS = [["processes", "#7c8cff"], ["ets", "#61e294"], ["binary", "#ffd166"], ["code", "#7fe0ff"], ["atom", "#c792ea"], ["system", "#8b93a7"]];

export class BeamPanel {
  constructor({ onOpen, onExplore, onApps }) {
    this.el = $("beam");
    this.onOpen = onOpen;
    this.unsub = null;
    this.waiters = [];
    this.level = "debug";
    this.filter = "";
    this.prev = new Map(); // id -> [reductions, at ms]: reductions/s between polls
    this.data = null;
    this.error = null;
    this.el.innerHTML = `
      <div class="bm-head"><h3>Under the hood <span class="unk">the observer's own BEAM</span></h3>
        <button class="iconbtn" data-close aria-label="Close">×</button></div>
      <button type="button" class="bm-apps" title="The observer's BEAM as a building: its OTP applications, supervision trees and processes">Applications floor ↗</button>
      <div class="bm-vm"></div>
      <h4>Supervision tree <span class="unk">ObsFactor.Supervisor, one_for_one</span></h4>
      <div class="bm-procs"></div>
      <h4>ETS tables</h4>
      <div class="bm-tables"></div>
      <h4>Log <span class="unk bm-logcount"></span><button type="button" class="bm-explore">Search all logs ↗</button></h4>
      <div class="bm-logctl">
        <select aria-label="Lowest level">${LEVELS.map((l) => `<option value="${l}">${l} and worse</option>`).join("")}</select>
        <input type="search" placeholder="filter, e.g. source docker" aria-label="Filter log lines" spellcheck="false">
      </div>
      <pre class="bm-log"></pre>`;
    this.vmEl = this.el.querySelector(".bm-vm");
    this.procEl = this.el.querySelector(".bm-procs");
    this.tabEl = this.el.querySelector(".bm-tables");
    this.logEl = this.el.querySelector(".bm-log");
    this.el.querySelector("[data-close]").addEventListener("click", () => this.toggle(false));
    this.el.querySelector(".bm-apps").addEventListener("click", () => onApps?.());
    this.el.querySelector(".bm-explore").addEventListener("click", () => onExplore?.({ service: ["observer"], query: this.filter }));
    this.logEl.title = "Click to search these logs";
    this.logEl.addEventListener("click", () => { if (!window.getSelection()?.toString()) onExplore?.({ service: ["observer"], query: this.filter }); });
    this.el.querySelector("select").addEventListener("change", (e) => { this.level = e.target.value; this.renderLog(); });
    this.el.querySelector("input").addEventListener("input", (e) => { this.filter = e.target.value.trim().toLowerCase(); this.renderLog(); });
  }

  get open() { return !this.el.hidden; }

  toggle(open) {
    const want = open ?? this.el.hidden;
    this.el.hidden = !want;
    $("beambtn").setAttribute("aria-expanded", String(want));
    if (want) { this.onOpen?.(); this.load(); }
    else { this.unsub?.(); this.unsub = null; }
  }

  setFilter(text) {
    const input = this.el.querySelector("input");
    input.value = text; this.filter = text.toLowerCase(); this.renderLog();
  }

  // subscribes (once) and resolves on the next payload: the tour waits on it
  load() {
    const next = new Promise((resolve) => this.waiters.push(resolve));
    if (!this.unsub) {
      this.render();
      this.unsub = bus.subscribe(TOPIC, (event, p) => { if (event === "feed") this.take(p); }, {
        onJoin: (p) => { if (p.at) this.take(p); },
        onError: (reason) => { this.error = `${TOPIC} refused: ${reason}`; this.render(); this.flush(); },
      });
    }
    return next;
  }

  take(p) {
    if (p.error) this.error = p.error;
    else { this.data = p.data; this.error = null; }
    this.render();
    this.flush();
  }

  flush() { const w = this.waiters; this.waiters = []; w.forEach((r) => r(this.data)); }

  render() {
    if (this.error) {
      this.vmEl.innerHTML = `<p class="note err">${esc(TOPIC)}: ${esc(this.error)}${this.data ? ` (showing the read from ${esc(utc(new Date(this.data.at)))})` : ""}</p>`;
      if (!this.data) return;
    }
    const d = this.data;
    if (!d) { this.vmEl.innerHTML = '<p class="note">Loading…</p>'; return; }
    const v = d.vm, m = v.memory;
    const bar = MEM_PARTS.map(([k, c]) => `<span style="flex:${m[k] ?? 0};background:${c}" title="${k} ${esc(bytes(m[k]))}"></span>`).join("");
    if (!this.error) this.vmEl.innerHTML = `
      <div class="bm-tiles">
        <div class="t" data-tile="node"><b>${esc(v.node)}</b><span>OTP ${esc(v.otp)} · ERTS ${esc(v.erts)} · Elixir ${esc(v.elixir)}</span></div>
        <div class="t" data-tile="uptime"><b>${esc(duration(v.uptime_s))}</b><span>VM uptime</span></div>
        <div class="t" data-tile="sched"><b>${esc(v.schedulers)} <i>run queue ${esc(v.run_queue)}</i></b><span>schedulers online</span></div>
        <div class="t" data-tile="procs"><b>${esc(num(v.process_count))}</b><span>processes of ${esc(num(v.process_limit))} · ${esc(v.port_count)} ports · ${esc(v.ets_count)} ETS</span></div>
      </div>
      <div class="bm-mem" data-tile="memory"><div class="ch-head"><span class="l">memory</span><span class="v">${esc(bytes(m.total))}</span></div>
        <div class="stack">${bar}</div>
        <ul class="bm-memkey">${MEM_PARTS.map(([k, c]) => `<li style="--c:${c}"><span class="sw"></span>${k} <b>${esc(bytes(m[k]))}</b></li>`).join("")}</ul></div>`;

    const now = Date.parse(d.at);
    const rows = d.processes.map((p) => {
      const was = this.prev.get(p.id);
      const rps = was && p.reductions != null && now > was[1] ? (p.reductions - was[0]) / ((now - was[1]) / 1000) : null;
      if (p.reductions != null) this.prev.set(p.id, [p.reductions, now]);
      const s = p.source;
      // No pid and a non-pid id: the child's init returned :ignore (DNSCluster
      // with no query configured). Not started on purpose, so not "down".
      const ignored = !p.alive && p.pid === ":undefined";
      const lamp = s ? `<span class="lamp ${s.ok ? "working" : "down"}" title="${s.ok ? "last poll ok" : esc(s.error)}"></span>`
        : `<span class="lamp ${p.alive ? "idle" : ignored ? "unknown" : "down"}"></span>`;
      const srcLine = s ? `<div class="src ${s.ok ? "" : "bad"}">source <b>${esc(s.name)}</b> · polled ${esc((s.attempted_ms_ago / 1000).toFixed(1))} s ago${s.ok ? "" : ` · ${esc(s.error)}`}</div>` : "";
      const q = p.message_queue_len;
      return `<tr data-proc="${esc(p.id)}"${s ? ` data-source="${esc(s.name)}"` : ""}>
        <td>${lamp}</td>
        <td><div class="nm">${esc(p.id)}${p.children != null ? ` <span class="unk">${p.children} children</span>` : ""}</div>
          <div class="fn">${ignored ? "not started: its init returned :ignore" : `${esc(p.pid)} · ${esc(p.status ?? (p.alive ? "" : "not running"))}`}${p.current_function ? ` in ${esc(p.current_function)}` : ""}</div>${srcLine}</td>
        <td class="r${q > 10 ? " warn" : ""}" title="messages waiting in its mailbox">${q == null ? UNKNOWN : esc(q)}</td>
        <td class="r">${p.memory_bytes == null ? UNKNOWN : esc(bytes(p.memory_bytes))}</td>
        <td class="r" title="reductions per second since the last read: how much work it did">${rps == null ? '<span class="unk">…</span>' : esc(num(rps))}</td></tr>`;
    }).join("");
    this.procEl.innerHTML = `<table class="bm-t"><thead><tr><th></th><th>process</th><th class="r">mailbox</th><th class="r">memory</th><th class="r">reds/s</th></tr></thead><tbody>${rows}</tbody></table>`;
    this.tabEl.innerHTML = `<table class="bm-t"><thead><tr><th>table</th><th>type</th><th class="r">rows</th><th class="r">memory</th></tr></thead><tbody>${d.tables.map((t) => `<tr data-table="${esc(t.name)}"><td class="nm">${esc(t.name)}</td><td>${esc(t.type)}</td><td class="r">${esc(num(t.size))}</td><td class="r">${esc(bytes(t.memory_bytes))}</td></tr>`).join("")}</tbody></table>`;
    this.renderLog();
  }

  renderLog() {
    const d = this.data;
    if (!d) return;
    const stuck = this.logEl.scrollTop + this.logEl.clientHeight >= this.logEl.scrollHeight - 8;
    const floor = RANK.indexOf(this.level);
    const lines = d.log.filter((l) => RANK.indexOf(l.level) >= floor).filter((l) => !this.filter || `${l.level} ${l.text} ${l.where ?? ""}`.toLowerCase().includes(this.filter));
    this.el.querySelector(".bm-logcount").textContent = `${lines.length} shown · the last ${d.log_kept} events are kept in memory`;
    this.logEl.innerHTML = lines.length
      ? lines.map((l) => `<span class="lt">${esc(utc(new Date(l.at)))}</span> <span class="lv ${esc(l.level)}">${esc(l.level.slice(0, 4))}</span> ${esc(l.text)}${l.where ? ` <span class="lw">${esc(l.where)}</span>` : ""}`).join("\n")
      : '<span class="unk">no lines match</span>';
    if (stuck) this.logEl.scrollTop = this.logEl.scrollHeight;
  }

  // for the tour: the first log line matching `test`, as an element
  markLine(test) {
    const d = this.data;
    if (!d) return null;
    const i = d.log.findIndex(test);
    if (i < 0) return null;
    this.level = "debug"; this.el.querySelector("select").value = "debug";
    this.setFilter("");
    const spans = this.logEl.querySelectorAll(".lt");
    const el = spans[i];
    if (el) el.scrollIntoView({ block: "center" });
    return el ?? null;
  }
}
