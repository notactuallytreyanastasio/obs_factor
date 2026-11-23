// The jump list: Cmd+K / Ctrl+K from anywhere. One box over the buildings on
// the floor, the objectives (the "objectives" topic on the page's socket,
// joined while the list is open), and the processes the Processes panel has
// seen lately. Enter goes there: a building or an objective flies to its
// building, a process opens in the Processes panel.

import * as bus from "./bus.js";
import { esc, num, bytes } from "./fmt.js";

const MAX = 40;

export class JumpList {
  // api: outer() the floor, go(id) -> null | why not, recent() processes
  // (newest first), openProc(row)
  constructor(api) {
    this.api = api;
    this.objectives = new Map();
    this.objError = null;
    this.objLoaded = false;
    this.unsub = null;
    this.items = [];
    this.whys = new Map(); // why a choice could not go, until the list closes
    this.at = 0;
    this.el = document.createElement("div");
    this.el.id = "jump";
    this.el.hidden = true;
    this.el.innerHTML = `<div class="jp-box" role="dialog" aria-label="Jump to">
      <input type="search" spellcheck="false" autocomplete="off" placeholder="Jump to a building, an objective or a process" aria-label="Jump to">
      <p class="jp-err" hidden></p>
      <ul class="jp-list" role="listbox"></ul>
      <p class="jp-keys unk">↑↓ pick · Enter go · Esc close</p></div>`;
    document.body.appendChild(this.el);
    this.input = this.el.querySelector("input");
    this.listEl = this.el.querySelector(".jp-list");
    this.errEl = this.el.querySelector(".jp-err");
    this.input.addEventListener("input", () => { this.at = 0; this.render(); });
    this.el.addEventListener("click", (e) => {
      if (e.target === this.el) { this.close(); return; }
      const li = e.target.closest("li[data-i]");
      if (li) this.choose(+li.dataset.i);
    });
    document.getElementById("jumpbtn")?.addEventListener("click", () => this.open());
    document.addEventListener("keydown", (e) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === "k") {
        e.preventDefault(); e.stopPropagation();
        this.el.hidden ? this.open() : this.close();
        return;
      }
      if (this.el.hidden) return;
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); this.close(); }
      else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault(); e.stopPropagation();
        this.at = Math.max(0, Math.min(this.items.length - 1, this.at + (e.key === "ArrowDown" ? 1 : -1)));
        this.render();
      } else if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); this.choose(this.at); }
    }, true);
  }

  get isOpen() { return !this.el.hidden; }

  open() {
    this.el.hidden = false;
    this.input.value = "";
    this.at = 0;
    if (!this.unsub) {
      this.unsub = bus.subscribe("objectives", (ev, p) => {
        if (ev === "objective") this.objectives.set(p.id, p);
        else if (ev === "list") this.setList(p.objectives);
        this.render();
      }, {
        onJoin: (r) => { if (r.objectives) { this.setList(r.objectives); this.objError = null; } else this.objError = r.error ?? "the objectives join answered neither objectives nor error"; this.objLoaded = true; this.render(); },
        onError: (reason) => { this.objError = `objectives refused: ${reason}`; this.render(); },
      });
    }
    this.render();
    this.input.focus();
  }

  close() {
    this.el.hidden = true;
    this.whys.clear();
    this.unsub?.(); this.unsub = null;
  }

  setList(list) { this.objectives = new Map((list ?? []).map((o) => [o.id, o])); }

  all() {
    const outer = this.api.outer();
    const nodes = outer?.nodes ?? [];
    const label = (id) => nodes.find((n) => n.id === id)?.label ?? id;
    const out = [];
    for (const n of nodes) out.push({ kind: "building", text: n.label, sub: `${n.kind}${n.status ? ` · ${n.status}` : ""} · ${n.id}`, hay: `${n.label} ${n.id} ${n.kind}`, go: () => this.api.go(n.id) });
    const objs = [...this.objectives.values()].filter((o) => o.state !== "done").sort((a, b) => (a.severity === "alert" ? 0 : 1) - (b.severity === "alert" ? 0 : 1));
    for (const o of objs) out.push({ kind: "objective", sev: o.severity, text: o.title, sub: `${o.severity} · ${o.state}${o.node ? ` · ${label(o.node)}` : " · no building"}`, hay: `${o.title} ${o.node ?? ""} ${o.node ? label(o.node) : ""} ${o.state} ${o.severity}`, go: () => (o.node ? this.api.go(o.node) : "this objective is not about a building") });
    for (const r of this.api.recent()) {
      const where = `${r.src.label}${r.src.member ? ` (${r.src.member})` : ""}`;
      out.push({ kind: "process", text: `${r.name ?? r.initial ?? "-"} ${r.pid}`, sub: `${where} · mailbox ${num(r.mq)} · ${bytes(r.memory)} · seen ${Math.round((Date.now() - r.seen) / 1000)} s ago`, hay: `${r.name ?? ""} ${r.initial ?? ""} ${r.current ?? ""} ${r.pid} ${r.node} ${r.src.label} ${r.member ?? ""}`, go: () => { this.api.openProc(r); return null; } });
    }
    return out;
  }

  render() {
    if (this.el.hidden) return;
    {
      const words = this.input.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
      const all = this.all();
      const hits = words.length ? all.filter((x) => { const h = x.hay.toLowerCase(); return words.every((w) => h.includes(w)); }) : all;
      // a label that starts with what was typed first, then the rest in order
      const first = words[0];
      if (first) hits.sort((a, b) => (b.text.toLowerCase().startsWith(first) ? 1 : 0) - (a.text.toLowerCase().startsWith(first) ? 1 : 0));
      this.items = hits.slice(0, MAX);
      this.more = hits.length - this.items.length;
    }
    this.at = Math.min(this.at, Math.max(0, this.items.length - 1));
    const errs = [];
    if (this.objError) errs.push(`Objectives not listed: ${this.objError}`);
    else if (!this.objLoaded) errs.push("Objectives: joining…");
    if (!this.api.recent().length) errs.push("No processes seen yet: open Processes to list some.");
    this.errEl.hidden = !errs.length;
    this.errEl.textContent = errs.join(" ");
    this.listEl.innerHTML = this.items.map((x, i) => `<li data-i="${i}" role="option" aria-selected="${i === this.at}" class="k-${x.kind}${x.sev ? ` sev-${esc(x.sev)}` : ""}${i === this.at ? " on" : ""}">
      <span class="jp-kind">${x.kind}</span><span class="jp-text">${esc(x.text)}</span><span class="jp-sub unk">${esc(x.sub)}</span>${this.whys.has(x.kind + x.text) ? `<span class="jp-why">${esc(this.whys.get(x.kind + x.text))}</span>` : ""}</li>`).join("")
      + (this.items.length ? "" : `<li class="unk jp-none">Nothing matches.</li>`)
      + (this.more > 0 ? `<li class="unk jp-none">${this.more} more: keep typing</li>` : "");
    this.listEl.querySelector("li.on")?.scrollIntoView({ block: "nearest" });
  }

  choose(i) {
    const x = this.items[i];
    if (!x) return;
    const why = x.go();
    if (why) { this.whys.set(x.kind + x.text, why); this.render(); return; }
    this.close();
  }
}
