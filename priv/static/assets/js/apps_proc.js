// One process of the Applications floor, opened by a click on its building.
// Fed by observer:<node>:<member or ->:proc:<pid> (re-read every second on
// the server while this panel is open, and left when it closes). Actions are
// pushes of "action" on that same topic; what anyone does on this node comes
// in on "actions", so a viewer who did nothing still sees it.
//
// The panel follows a building, not a pid: when the tree feed shows the
// child under a new pid (restarted, by us or by its supervisor) the panel
// moves to it and says so.

import { num, bytes, esc, utc, UNKNOWN } from "./fmt.js";
import * as bus from "./bus.js";
import { topicOf } from "./apps.js";

const $ = (id) => document.getElementById(id);
const WHO_KEY = "obs_factor.who"; // the name missions.js keeps
const who = () => { try { return localStorage.getItem(WHO_KEY) || ""; } catch { return ""; } };
const setWho = (v) => { try { localStorage.setItem(WHO_KEY, v); return true; } catch { return false; } };
const u = (v, f = (x) => x) => (v == null || v === "" ? `<span class="unk">${UNKNOWN}</span>` : esc(f(v)));
const lampOf = (st) => ({ running: "working", runnable: "working", garbage_collecting: "working", waiting: "idle", suspended: "blocked", exiting: "down" })[st] ?? "unknown";

const ACTIONS = {
  kill: { label: "Kill", path: (pid) => `proc/${pid}/kill`, params: () => ({}), says: "kill (exit reason :kill, cannot be trapped)" },
  gc: { label: "GC", path: (pid) => `proc/${pid}/gc`, params: () => ({}), says: "garbage-collect" },
  exit: { label: "Exit(shutdown)", path: (pid) => `proc/${pid}/exit`, params: () => ({ reason: "shutdown" }), says: "send exit(shutdown) to" },
  restart: { label: "Restart", path: (_, o) => `tree/${o.app}/restart`, params: (o) => ({ supervisor: o.parent, child_id: o.child_id }), says: "restart, through its supervisor," },
};

export class ProcPanel {
  constructor({ onClose, onPid }) {
    this.el = $("apps-proc");
    this.onClose = onClose;
    this.onPid = onPid;
    this.target = null; // {node, member, label, nodeId}
    this.n = null; // the floor node (otp fields)
    this.pid = null;
    this.data = null; this.error = null; this.at = null;
    this.unsub = null; this.actUnsub = null;
    this.confirm = null; // action key waiting for a yes
    this.result = null; // {ok, text}
    this.busy = false;
    this.moved = null; // "was 0.1.0, now 0.2.0"
    this.seen = []; // actions on this node from the "actions" topic
    this.el.innerHTML = `<div class="grab" aria-hidden="true"></div>
      <button class="iconbtn close" data-close aria-label="Close">
        <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg></button>
      <div class="ap-body"></div>`;
    this.body = this.el.querySelector(".ap-body");
    this.el.querySelector("[data-close]").addEventListener("click", () => this.close());
    this.body.addEventListener("click", (e) => this.click(e));
    this.body.addEventListener("submit", (e) => {
      e.preventDefault();
      const v = e.target.querySelector("input")?.value.trim();
      if (!v) return;
      this.whoNote = setWho(v) ? null : "this browser will not keep it";
      this.whoName = v;
      this.render();
    });
    window.addEventListener("keydown", (e) => { if (e.key === "Escape" && this.open && !e.defaultPrevented) { e.preventDefault(); this.close(); } });
  }

  get open() { return this.n != null; }
  get topic() { return topicOf(this.target.node, this.target.member, `proc:${this.pid}`); }

  // n: a floor node from apps.js with n.otp; target: whose BEAM it is
  show(n, target) {
    const same = this.n && this.n.id === n.id && this.target?.node === target.node && this.target?.member === target.member;
    this.target = target;
    this.n = n;
    this.el.hidden = false;
    document.body.classList.add("ap-inspecting");
    if (!same) { this.confirm = null; this.result = null; this.moved = null; this.body.scrollTop = 0; }
    // the socket's state: while it is not connected the read below is not live
    if (!this.stateUnsub) this.stateUnsub = bus.onState((st) => { this.link = st; this.render(); });
    if (!this.actUnsub) {
      this.actUnsub = bus.subscribe("actions", (ev, a) => {
        if (ev !== "action" || !this.target || a.node !== this.target.node || (a.member ?? null) !== (this.target.member ?? null)) return;
        this.seen.unshift(a); this.seen = this.seen.slice(0, 6); this.render();
      });
    }
    this.watch(n.otp?.pid ?? null);
    this.render();
  }

  // the floor was rebuilt: the same building, maybe under another pid, or gone
  follow(n) {
    if (!this.open) return;
    if (!n) { this.gone = true; this.render(); return; }
    this.gone = false;
    const was = this.pid;
    this.n = n;
    const pid = n.otp?.pid ?? null;
    if (pid && was && pid !== was) this.moved = `was ${was}, now ${pid}: a new process under the same child id`;
    this.watch(pid);
    this.render();
  }

  watch(pid) {
    if (pid === this.pid && (this.unsub || !pid)) return;
    this.unsub?.(); this.unsub = null;
    this.pid = pid;
    this.data = null; this.error = null; this.at = null;
    if (!pid) return;
    const topic = this.topic;
    const take = (p) => {
      if (topic !== this.topic || !p?.at) return;
      this.at = p.at;
      if (p.error) this.error = p.error; else { this.data = p.data; this.error = null; }
      this.render();
    };
    this.unsub = bus.subscribe(topic, (ev, p) => ev === "feed" && take(p), {
      onJoin: take,
      onError: (reason) => { if (topic === this.topic) { this.error = `${topic} refused: ${reason}`; this.render(); } },
    });
  }

  close() {
    if (!this.open) return;
    this.unsub?.(); this.unsub = null;
    this.actUnsub?.(); this.actUnsub = null;
    this.stateUnsub?.(); this.stateUnsub = null;
    this.n = null; this.pid = null; this.data = null; this.seen = [];
    this.el.hidden = true;
    this.el.classList.remove("tall");
    document.body.classList.remove("ap-inspecting");
    this.onClose?.();
  }

  click(e) {
    const a = e.target.closest("[data-act]");
    if (a) { this.confirm = a.dataset.act; this.result = null; this.render(); return; }
    if (e.target.closest("[data-cancel]")) { this.confirm = null; this.render(); return; }
    if (e.target.closest("[data-yes]")) { this.run(this.confirm); return; }
    const p = e.target.closest("[data-pid]");
    if (p) { e.preventDefault(); this.onPid?.(p.dataset.pid); }
  }

  notLive() {
    const st = this.link ?? bus.state();
    return st.state === "connected" ? null : `${st.state}${st.detail ? `: ${st.detail}` : ""}`;
  }

  async run(key) {
    const act = ACTIONS[key];
    const o = this.n?.otp;
    const by = this.whoName || who();
    if (!act || !o || !this.pid || !by || this.notLive()) return;
    this.busy = true; this.render();
    const payload = { path: act.path(this.pid, o), params: act.params(o), by };
    try {
      const r = await bus.push(this.topic, "action", payload);
      this.result = { ok: true, text: describe(key, r) };
    } catch (x) {
      this.result = { ok: false, text: `${act.label} refused: ${x.message}` };
    }
    this.busy = false; this.confirm = null;
    this.render();
  }

  render() {
    if (!this.open) return;
    const n = this.n, o = n.otp ?? {}, d = this.data, t = this.target;
    const where = `${t.node}${t.member ? ` (${t.member})` : ""}`;
    const head = `<div class="ins-head"><h2>${esc(n.label)}</h2>
      <div class="sub">${esc(o.app ?? "")} · ${esc(o.type ?? "")} · ${esc(this.pid ?? "not running")} on ${esc(where)}</div>
      <div class="status-pill st-${lampOf(d?.status ?? o.status)}"><span class="lamp ${lampOf(d?.status ?? o.status)}"></span>${esc(d?.status ?? o.status ?? (this.pid ? "unknown" : "not running"))}</div></div>`;
    const down = this.notLive();
    const notes = [
      down ? `<p class="note err">Not live (${esc(down)}): actions are off until the socket is back${d ? `; the read below is from ${esc(utc(new Date(this.at)))}` : ""}.</p>` : "",
      this.gone ? '<p class="note err">This building is no longer on the floor: the tree feed no longer lists it.</p>' : "",
      this.moved ? `<p class="note ap-moved">${esc(this.moved)}</p>` : "",
      !this.pid ? `<p class="note err">${esc(n.reason ?? "not running: nothing to read")}</p>` : "",
      this.error ? `<p class="note err">${esc(this.error)}${d ? ` (showing the read from ${esc(utc(new Date(this.at)))})` : ""}</p>` : "",
      this.pid && !d && !this.error ? `<p class="note">Joining ${esc(this.topic)}…</p>` : "",
    ].join("");
    this.body.innerHTML = head + notes + this.actionsHtml(o, where) + (d ? this.detail(d) : "") + this.seenHtml();
  }

  actionsHtml(o, where) {
    if (!this.pid) return "";
    const by = this.whoName || who();
    const canRestart = o.parent && o.child_id;
    const keys = ["kill", "gc", "exit", ...(canRestart ? ["restart"] : [])];
    const off = this.busy || !!this.notLive();
    let body = `<div class="ap-acts">${keys.map((k) => `<button type="button" data-act="${k}"${off ? " disabled" : ""} class="${k === "kill" ? "danger" : ""}">${ACTIONS[k].label}</button>`).join("")}</div>`;
    if (!canRestart) body += `<p class="note">${o.parent ? "Restart needs the child id its supervisor knows it by; this one has none" : "Restart is for a supervisor's child; this is the application's top supervisor"}.</p>`;
    if (this.confirm) {
      const act = ACTIONS[this.confirm];
      const text = this.confirm === "restart"
        ? `Restart <b>${esc(this.n.label)}</b> (child ${esc(o.child_id)} of ${esc(o.parentLabel ?? o.parent)} ${esc(o.parent)}) on <b>${esc(where)}</b>?`
        : `${esc(act.says[0].toUpperCase() + act.says.slice(1))} <b>${esc(this.n.label)}</b> (${esc(this.pid)}) on <b>${esc(where)}</b>?`;
      body += by
        ? `<div class="ap-confirm" role="alertdialog"><p>${text}</p><p class="unk">as ${esc(by)}</p>
            <button type="button" data-yes class="${this.confirm === "kill" ? "danger" : ""}"${off ? " disabled" : ""}>${this.busy ? "Sending…" : `Yes, ${esc(act.label)}`}</button>
            <button type="button" data-cancel>Cancel</button></div>`
        : `<form class="ap-confirm ap-who"><p>Who is acting? Every action is logged and shown to everyone watching, with this name.</p>
            <input name="who" maxlength="80" placeholder="your name" autocomplete="nickname" spellcheck="false"><button type="submit">That's me</button>
            <button type="button" data-cancel>Cancel</button></form>`;
    }
    if (this.whoNote) body += `<p class="note">${esc(this.whoNote)}</p>`;
    if (this.result) body += `<p class="note ${this.result.ok ? "ap-ok" : "err"}">${esc(this.result.text)}</p>`;
    return `<div class="sec"><h3>Act</h3>${body}</div>`;
  }

  detail(d) {
    const kv = (rows) => `<dl class="kv">${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v}</dd>`).join("")}</dl>`;
    const pidLink = (x) => (x.pid ? `<a href="#" data-pid="${esc(x.pid)}">${esc(x.pid)}</a>${x.registered_name ? ` ${esc(x.registered_name)}` : ""}` : x.port ? `port ${esc(x.port)}` : esc(JSON.stringify(x)));
    const list = (xs, count) => (xs?.length ? `${xs.map(pidLink).join(", ")}${count > xs.length ? ` <span class="unk">and ${count - xs.length} more</span>` : ""}` : '<span class="unk">none</span>');
    const gc = d.garbage_collection ?? {};
    const st = d.state;
    const stateText = st == null ? '<span class="unk">not in the answer</span>'
      : st.status === "not requested" ? '<span class="unk">not requested: the feed reads without state=true, and the app must set inspect_state: true for the engine to give it</span>'
        : `<pre class="ap-pre">${esc(typeof st === "string" ? st : JSON.stringify(st, null, 1))}</pre>`;
    return `
      <div class="sec"><h3>Process <span class="unk">read ${esc(utc(new Date(this.at)))}, ${esc(d.took_ms)} ms${this.notLive() ? " · not live" : ""}</span></h3>${kv([
        ["registered", u(d.registered_name)], ["application", u(d.application)], ["in", u(d.current_function)], ["started as", u(d.initial_call)],
        ["mailbox", `${esc(num(d.message_queue_len))} messages`], ["memory", esc(bytes(d.memory))], ["reductions", esc(num(d.reductions))],
        ["heap / total heap", `${esc(num(d.heap_size_words))} / ${esc(num(d.total_heap_size_words))} words`], ["stack", `${esc(num(d.stack_size_words))} words`],
        ["traps exits", esc(String(d.trap_exit))], ["priority", u(d.priority)], ["group leader", d.group_leader ? pidLink({ pid: d.group_leader }) : u(null)],
        ["supervised by", (d.supervisor_path ?? []).length ? d.supervisor_path.map(pidLink).join(" ← ") : '<span class="unk">none found</span>'],
      ])}</div>
      <div class="sec"><h3>Garbage collection</h3>${kv(Object.entries(gc).map(([k, v]) => [k.replace(/_/g, " "), esc(num(v))]))}</div>
      <div class="sec"><h3>Stacktrace <span class="unk">${(d.current_stacktrace ?? []).length} frames</span></h3>
        <ol class="ap-stack">${(d.current_stacktrace ?? []).map((f) => `<li><b>${esc(f.mfa)}</b>${f.file ? ` <span class="unk">${esc(f.file)}:${esc(f.line ?? "?")}</span>` : ""}</li>`).join("") || '<li class="unk">empty</li>'}</ol></div>
      <div class="sec"><h3>Links and monitors</h3>${kv([
        [`links (${d.links_count ?? 0})`, list(d.links, d.links_count)], [`monitors (${d.monitors_count ?? 0})`, list(d.monitors, d.monitors_count)],
        [`monitored by (${d.monitored_by_count ?? 0})`, list(d.monitored_by, d.monitored_by_count)],
      ])}</div>
      <div class="sec"><h3>Dictionary <span class="unk">${d.dictionary_not_read ? "not listed" : `${esc(d.dictionary_count ?? 0)} keys, names only`}</span></h3>
        <div class="ap-keys">${d.dictionary_not_read ? `<span class="unk">${esc(d.dictionary_not_read)}</span>` : (d.dictionary_keys ?? []).map((k) => `<code>${esc(k)}</code>`).join(" ") || '<span class="unk">empty</span>'}</div></div>
      <div class="sec"><h3>State</h3>${stateText}</div>`;
  }

  seenHtml() {
    if (!this.seen.length) return "";
    return `<div class="sec"><h3>Done on this node <span class="unk">by anyone, since you opened this</span></h3><ul class="ap-seen">${this.seen.map((a) => `<li class="${a.error ? "bad" : ""}">
      <time>${esc(utc(new Date(a.at)))}</time> <b>${esc(a.path)}</b> by ${esc(a.by ?? "nobody said")}: ${a.error ? esc(`${a.status}: ${a.error}`) : esc(`${a.status} ok`)}</li>`).join("")}</ul></div>`;
  }
}

function describe(key, r) {
  if (key === "gc") return `GC done: ${bytes(r.memory_before)} before, ${bytes(r.memory_after)} after`;
  if (key === "restart") return `Restarted: ${r.old_pid ?? "?"} is now ${r.new_pid ?? "?"}`;
  if (key === "kill") return `Killed ${r.pid}: alive after: ${r.alive_after}, exit reason ${r.exit_reason ?? "?"}`;
  if (key === "exit") return `Sent exit(${r.reason}) to ${r.pid}: alive after: ${r.alive_after}${r.exit_reason ? `, exit reason ${r.exit_reason}` : ""}`;
  return JSON.stringify(r);
}
