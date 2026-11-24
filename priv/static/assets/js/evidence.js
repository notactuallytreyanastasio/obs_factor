// Evidence: what a BEAM was doing when the wire flagged it
// (ObsFactor.Evidence, the `evidence` channel). The board's Wire and Errors
// tabs ask `tag(item)` for an "evidence" expander on each item that has a
// capture; opened, it shows the top processes three ways (reductions/s over
// 500 ms, memory, mailbox) with their names, initial calls and current
// functions, the biggest ETS tables, the Repo tables, the LiveViews alive
// and the last logged events, as captured at that moment.
//
// A live item has no tape id until it is read back, so a capture is found
// by its links either way: the tape_wire id, or time|app|member|kind.

import * as bus from "./bus.js";
import { esc, num, bytes } from "./fmt.js";

const pad = (n) => String(n).padStart(2, "0");
const hms = (ms) => { const d = new Date(ms); return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`; };
const short = (s) => String(s ?? "").replace(/Elixir\./g, "").replace(/^:/, "");
const keyOf = (w) => `${w.at}|${w.app ?? ""}|${w.member ?? ""}|${w.kind}`;
const procName = (p) => p.registered_name ? short(p.registered_name) : `${short(p.initial_call ?? "?")} ${p.pid}`;

export class Evidence {
  constructor(onChange) {
    this.onChange = onChange;
    this.entries = new Map(); // evidence id -> index entry
    this.links = new Map(); // "id:<wire id>" | keyOf(item) -> evidence id
    this.full = new Map(); // evidence id -> whole capture (body), once opened
    this.open = new Set(); // "<where>:<evidence id>" expanded
    this.error = null;
    bus.subscribe("evidence", (ev, e) => { if (ev === "captured") { this.add(e); this.onChange(); } }, {
      onJoin: (r) => { this.error = r.error ?? null; },
    });
  }

  // the captures for [from, to]: the board's window
  load(from, to) {
    if (this.error) return;
    bus.push("evidence", "index", { from: Math.round(from), to: Math.round(to) })
      .then((r) => { for (const e of r.evidence) this.add(e); this.onChange(); })
      .catch((x) => console.error(`obs_factor evidence: ${x.message}`));
  }

  add(e) {
    this.entries.set(e.id, e);
    for (const l of e.links ?? []) {
      if (l.wire_id != null) this.links.set(`id:${l.wire_id}`, e.id);
      this.links.set(keyOf(l), e.id);
    }
  }

  find(w) { return w ? (w.id != null && this.links.get(`id:${w.id}`)) || this.links.get(keyOf(w)) || null : null; }

  // the expander for one item (`where`: "wire" or "errors", so the same
  // capture can be open in one tab and shut in the other); "" when none
  tag(w, where) {
    const id = this.find(w);
    if (!id) return "";
    const e = this.entries.get(id);
    const k = `${where}:${id}`;
    const on = this.open.has(k);
    const hot = e?.hot?.name ? ` · ${esc(short(e.hot.name))}${e.hot.reductions_per_s != null ? ` ${num(e.hot.reductions_per_s)}/s` : ""}` : "";
    const btn = `<button type="button" class="ev-btn" data-ev="${k}" aria-expanded="${on}" title="What this BEAM was doing at that moment">evidence${hot}</button>`;
    return btn + (on ? `<div class="ev-body" data-evbody>${this.body(id, w)}</div>` : "");
  }

  // a click on an expander: true when it was one (the board stops there)
  click(e) {
    const b = e.target.closest("[data-ev]");
    if (!b) return !!e.target.closest("[data-evbody]"); // a click inside the evidence is not a replay
    e.stopPropagation();
    const k = b.dataset.ev, id = Number(k.slice(k.indexOf(":") + 1));
    if (this.open.has(k)) this.open.delete(k); else this.open.add(k);
    if (this.open.has(k) && !this.full.has(id)) {
      this.full.set(id, null); // loading
      bus.push("evidence", "get", { id })
        .then((r) => { this.full.set(id, r.evidence); this.onChange(); })
        .catch((x) => { this.full.set(id, { failed: x.message }); this.onChange(); });
    }
    this.onChange();
    return true;
  }

  body(id, w) {
    const c = this.full.get(id);
    if (c === undefined || c === null) return `<p class="ev-dim">reading the capture…</p>`;
    if (c.failed) return `<p class="ev-err">${esc(c.failed)}</p>`;
    const b = c.body ?? {};
    const link = (c.links ?? []).find((l) => (w.id != null && l.wire_id === w.id) || keyOf(l) === keyOf(w));
    const when = link && link.captured_before_ms > 0 ? `, ${Math.round(link.captured_before_ms / 1000)} s before this item (one capture per BEAM a minute)` : "";
    const p = b.procs ?? {};
    const procs = (title, rows, val) => rows?.length
      ? `<div><h5>${title}</h5><table><tbody>${rows.map((r) => `<tr><td class="ev-n">${esc(procName(r))}</td><td class="ev-f">${esc(short(r.current_function ?? ""))}</td><td class="r">${val(r)}</td></tr>`).join("")}</tbody></table></div>`
      : "";
    const ets = b.ets?.length
      ? `<div><h5>ETS, biggest</h5><table><tbody>${b.ets.map((t) => `<tr><td class="ev-n">${esc(short(t.name))}</td><td class="ev-f">${esc(short(t.owner_name ?? t.owner ?? ""))}</td><td class="r">${bytes(t.memory_bytes)} · ${num(t.size)}</td></tr>`).join("")}</tbody></table></div>`
      : "";
    const tables = b.tables?.length
      ? `<div><h5>Repo tables</h5><table><tbody>${b.tables.map((t) => `<tr><td class="ev-n">${esc(t.table ?? "(no table)")}</td><td class="ev-f">${esc(short(t.repo ?? ""))}</td><td class="r">${t.rate != null ? `${num(t.rate)}/s` : num(t.count)}${t.avg_ms != null ? ` · ${num(t.avg_ms)} ms` : ""}</td></tr>`).join("")}</tbody></table></div>`
      : "";
    const lv = b.liveviews?.views?.length
      ? `<h5>LiveViews alive${b.liveviews.total != null ? `: ${num(b.liveviews.total)}` : ""}</h5><p class="ev-dim">${b.liveviews.views.map((v) => `${esc(short(v.view))} ${num(v.alive)}`).join(" · ")}</p>`
      : "";
    const events = b.events?.length
      ? `<h5>Logged, newest first</h5><ul class="ev-log">${b.events.slice(0, 8).map((e) => `<li><b>${esc(e.level ?? "")}</b> ${esc(short(e.name ?? ""))}: ${esc(e.message ?? "")}</li>`).join("")}</ul>`
      : "";
    const errs = b.errors?.length ? `<ul class="ev-err">${b.errors.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>` : "";
    return `<p class="ev-dim">captured ${hms(c.at)} on ${esc(c.member ?? c.address ?? c.app)}${c.address ? ` (${esc(c.address)})` : ""}${when}; took ${num(b.took_ms)} ms</p>${errs}
      <div class="ev-grid">
        ${procs("Hottest, reductions/s over 500 ms", p.reductions, (r) => `${num(r.reductions_per_s)}/s`)}
        ${procs("Biggest, memory", p.memory, (r) => bytes(r.memory))}
        ${procs("Mailboxes", (p.message_queue_len ?? []).filter((r) => r.message_queue_len > 0), (r) => num(r.message_queue_len))}
        ${ets}${tables}
      </div>${lv}${events}`;
  }
}
