// deploys.js: what code went out, on the timeline. Each deploy the
// observer kept (ObsFactor.Deploys, from the box's .deployed files) is a
// dotted line through the strip with its short sha, "+" when it went out
// dirty. The `deploys` channel gives the last 31 days on join (the most the
// timeline shows) and pushes each new one.
//
// Drawn through the timeline's overlay hook (timeline.js `overlays`), so
// the marks pan and zoom with it. Labels are placed newest first, right of
// the line or, at the live edge, left of it; one that would overlap a newer
// one is left off (its line is still drawn).

import * as bus from "./bus.js";

const COLOR = "#8fd3ff";

export class DeployMarks {
  constructor({ timeline, label }) {
    this.timeline = timeline;
    this.label = label;
    this.list = [];
    this.error = null;
    timeline.overlays ??= [];
    timeline.overlays.push((ctx, v) => this.draw(ctx, v));
    bus.subscribe("deploys", (event, d) => {
      if (event !== "deploy") return;
      if (!this.list.some((x) => x.id === d.id)) this.list.push(d);
      this.list.sort((a, b) => a.at - b.at);
      this.redraw();
    }, {
      onJoin: (r) => {
        this.list = r.deploys ?? [];
        this.error = r.error ?? null;
        if (this.error) console.warn(`obs_factor deploys: ${this.error}`);
        this.redraw();
      },
      onError: (reason) => console.error(`obs_factor deploys: refused: ${reason}`),
    });
  }

  redraw() { if (!this.timeline.el?.hidden) this.timeline.draw(); }

  // `9047a85+` for a dirty deploy: what is in the box is not that commit alone
  static short(d) { return `${d.sha.slice(0, 7)}${d.dirty ? "+" : ""}`; }

  draw(ctx, { X, x0, w, h, L }) {
    if (!this.list.length) return;
    ctx.save();
    ctx.font = "9px ui-monospace, Menlo, monospace";
    ctx.textBaseline = "middle";
    const y = L.ovY + Math.round(L.ovH / 2);
    let freeTo = Infinity; // every label drawn so far starts at or after this x
    for (let i = this.list.length - 1; i >= 0; i--) {
      const d = this.list[i];
      const x = X(d.at);
      if (x < x0 - 60 || x > w + 2) continue;
      ctx.strokeStyle = "rgba(143,211,255,0.5)";
      ctx.setLineDash([1, 2]);
      ctx.beginPath(); ctx.moveTo(x + 0.5, L.ovY); ctx.lineTo(x + 0.5, h - 11); ctx.stroke();
      ctx.setLineDash([]);
      const text = DeployMarks.short(d);
      const tw = ctx.measureText(text).width + 4;
      const room = Math.min(w, freeTo - 3);
      const lx = x + 1 + tw <= room ? x + 1 : x - tw;
      if (lx < x0 || lx + tw > room) continue;
      ctx.fillStyle = "rgba(10,16,24,0.85)";
      ctx.fillRect(lx, y - 6, tw, 12);
      ctx.fillStyle = COLOR;
      ctx.fillText(text, lx + 2, y);
      freeTo = lx;
    }
    ctx.restore();
  }

  // for a tooltip or a test: the deploys within `px` of x, nearest first
  near(x, px = 6) {
    const X = (t) => this.timeline.X(t);
    return this.list.filter((d) => Math.abs(X(d.at) - x) <= px)
      .sort((a, b) => Math.abs(X(a.at) - x) - Math.abs(X(b.at) - x))
      .map((d) => ({ ...d, who: this.label(d.node) }));
  }
}
