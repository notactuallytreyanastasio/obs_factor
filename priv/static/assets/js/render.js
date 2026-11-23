// The factory floor: platforms, belts with items, buildings, power lines,
// smoke and fire. Draws one frame from the current snapshot and camera.

import { P, TW, TH, ZH, box, poly, line, glow, alpha, shade, tone, hull, inPoly } from "./iso.js";
import { drawBuilding, drawFittings, drawPad, drawPadRing, drawLamp, chimneys, heightOf, STATUS_COLOR } from "./buildings.js";
import { layout, routeBelts, topoKey, FOOT } from "./layout.js";
import { isNum } from "./fmt.js";

// "dist": bytes between the nodes of a cluster (inside.js, clusterRooms)
export const ITEM_COLOR = { requests: "#ffd166", commits: "#4cc9f0", prompts: "#f472b6", dist: "#b69cff" };
const EXTRA = ["#90be6d", "#f9844a", "#b388ff", "#43aa8b", "#f94144"];
export const CPU_COLOR = "#ff7a45";
export const MEM_COLOR = "#7c8cff";
export const HOLD_COLORS = ["#f2c94c", "#4c9aff", "#6cc04a", "#ec6a8c", "#b28dff", "#4fd1c5", "#f2994a", "#9aa5b8"];
const ACCENTS = ["#e9b949", "#4cc9f0", "#f77f00", "#90be6d", "#f15bb5", "#9b5de5", "#00bbf9", "#43aa8b"];

// Belt items by status class: what came back, not what went in.
export const CLASS_COLOR = { "2xx": "#ffd166", "3xx": "#6ab7ff", "4xx": "#c77dff", "5xx": "#ff4d4d", other: "#dfe6f2" };
const CLASS_ORDER = ["2xx", "3xx", "4xx", "5xx", "other"];
const CONTAINER_STEPS = [1e6, 2.5e6, 5e6, 1e7, 2.5e7, 5e7, 1e8, 2.5e8, 5e8, 1e9, 2.5e9, 5e9, 1e10, 2.5e10, 5e10, 1e11];
const MAX_CONTAINERS = 30;

// How many containers each hold gets, and what one container stands for.
export function containerPlan(holds) {
  const known = (holds ?? []).filter((h) => isNum(h.bytes) && h.bytes > 0);
  if (!known.length) return { unit: null, counts: [] };
  const total = known.reduce((a, h) => a + h.bytes, 0);
  const unit = CONTAINER_STEPS.find((u) => known.reduce((a, h) => a + Math.max(1, Math.round(h.bytes / u)), 0) <= MAX_CONTAINERS)
    ?? Math.ceil(total / MAX_CONTAINERS);
  return { unit, counts: (holds ?? []).map((h) => (isNum(h.bytes) && h.bytes > 0 ? Math.max(1, Math.round(h.bytes / unit)) : 0)) };
}

export const hashStr = (s) => [...s].reduce((h, c) => (Math.imul(h, 31) + c.charCodeAt(0)) | 0, 7) >>> 0;
export const itemColor = (item) => ITEM_COLOR[item] ?? EXTRA[hashStr(item ?? "") % EXTRA.length];

// Belt look from rate, log scale. u: 0 at 0.01/s, 1 at 1000/s.
export function beltMotion(rate) {
  const u = Math.max(0, Math.min(1, (Math.log10(Math.max(rate, 1e-9)) + 2) / 5));
  return { spacing: 2.4 - 1.8 * u, speed: 0.45 + 2.6 * u, u };
}

export class Scene {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.cam = { x: 0, y: 0, z: 0.6 };
    this.view = { w: 1, h: 1, dpr: 1 };
    this.snap = null;
    this.world = null;
    this.routes = new Map();
    this.problems = [];
    this.key = null;
    this.selected = null;
    this.hover = null;
    this.flash = null; // {id, until}
    this.focus = null; // the issues lens: Map node id -> "alert" | "warn", or null
    this.motion = true;
    this.tall = false;
  }

  // Portrait screens stack the platforms down the screen. Returns true when
  // that changed the layout.
  setTall(tall) {
    if (tall === this.tall) return false;
    this.tall = tall;
    if (this.snap) this.setSnapshot(this.snap);
    return !!this.snap;
  }

  resize(w, h) {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.view = { w, h, dpr };
    this.canvas.width = Math.round(w * dpr);
    this.canvas.height = Math.round(h * dpr);
    this.canvas.style.width = `${w}px`;
    this.canvas.style.height = `${h}px`;
  }

  // Returns true when the layout changed (camera may want to re-fit).
  setSnapshot(snap) {
    this.snap = snap;
    this.nodeById = new Map(snap.nodes.map((n) => [n.id, n]));
    const key = `${this.tall ? "tall" : "wide"}|${topoKey(snap)}`;
    let changed = false;
    if (key !== this.key) {
      this.key = key;
      this.world = layout(snap, { tall: this.tall });
      const r = routeBelts(this.world, snap.edges);
      this.routes = r.routes;
      this.problems = [...this.world.problems, ...r.problems];
      for (const msg of this.problems) console.error(`obs_factor layout: ${msg}`);
      for (const b of this.world.nodes.values()) {
        const h = heightOf(b.node);
        b.h = h;
        b.hull = hull([
          P(b.x - 0.2, b.y - 0.2, 0), P(b.x + 3.2, b.y - 0.2, 0), P(b.x + 3.2, b.y + 3.2, 0), P(b.x - 0.2, b.y + 3.2, 0),
          P(b.x, b.y, h), P(b.x + 3, b.y, h), P(b.x + 3, b.y + 3, h), P(b.x, b.y + 3, h),
        ]);
        b.seed = hashStr(b.node.id);
        b.accent = ACCENTS[b.seed % ACCENTS.length];
      }
      this.order = [...this.world.nodes.values()].sort((a, b) => a.x + a.y - (b.x + b.y) || a.x - b.x);
      this.platOrder = [...this.world.platforms].sort((a, b) => a.x + a.y - (b.x + b.y));
      changed = true;
    }
    // refresh node objects on placed entries (same ids, new values)
    for (const b of this.world.nodes.values()) b.node = this.nodeById.get(b.node.id) ?? b.node;
    for (const r of this.routes.values()) r.edge = snap.edges.find((e) => e.id === r.edge.id) ?? r.edge;
    return changed;
  }

  // ---- camera -------------------------------------------------------------

  toScreen([wx, wy]) {
    const { w, h } = this.view;
    return [(wx - this.cam.x) * this.cam.z + w / 2, (wy - this.cam.y) * this.cam.z + h / 2];
  }
  toWorld([sx, sy]) {
    const { w, h } = this.view;
    return [(sx - w / 2) / this.cam.z + this.cam.x, (sy - h / 2) / this.cam.z + this.cam.y];
  }
  worldBounds() {
    const b = this.world.bounds;
    const pts = [P(b.x0, b.y0), P(b.x1, b.y0), P(b.x1, b.y1), P(b.x0, b.y1)];
    pts.push(P(b.x0, b.y0, 4));
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    return { x0: Math.min(...xs), x1: Math.max(...xs), y0: Math.min(...ys), y1: Math.max(...ys) + 30 };
  }
  // Fit the whole floor into the free area of the viewport.
  fit(free) {
    const wb = this.worldBounds();
    const fw = free.w, fh = free.h;
    const z = Math.min(fw / (wb.x1 - wb.x0), fh / (wb.y1 - wb.y0)) * 0.96;
    this.cam.z = clampZoom(z);
    const cx = (wb.x0 + wb.x1) / 2, cy = (wb.y0 + wb.y1) / 2;
    // centre of the free area in screen space
    const sx = free.x + fw / 2, sy = free.y + fh / 2;
    this.cam.x = cx - (sx - this.view.w / 2) / this.cam.z;
    this.cam.y = cy - (sy - this.view.h / 2) / this.cam.z;
  }
  nodeAnchor(id, dz = 0.4) {
    const b = this.world?.nodes.get(id);
    if (!b) return null;
    return P(b.x + FOOT / 2, b.y + FOOT / 2, b.h + dz);
  }
  nodeCenter(id) {
    const b = this.world?.nodes.get(id);
    return b ? P(b.x + FOOT / 2, b.y + FOOT / 2, b.h / 2) : null;
  }

  hit(sx, sy) {
    if (!this.world) return null;
    const p = this.toWorld([sx, sy]);
    for (let i = this.order.length - 1; i >= 0; i--) {
      const b = this.order[i];
      if (inPoly(p, b.hull)) return b.node.id;
    }
    return null;
  }

  // ---- frame --------------------------------------------------------------

  draw(tMs) {
    const { ctx } = this;
    const { w, h, dpr } = this.view;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    if (!this.world) return;
    const t = this.motion ? tMs / 1000 : 0;
    const z = this.cam.z;
    ctx.setTransform(dpr * z, 0, 0, dpr * z, dpr * (w / 2 - this.cam.x * z), dpr * (h / 2 - this.cam.y * z));
    ctx.lineJoin = "round";

    const vw = { x0: this.cam.x - w / 2 / z - 120, x1: this.cam.x + w / 2 / z + 120, y0: this.cam.y - h / 2 / z - 160, y1: this.cam.y + h / 2 / z + 120 };
    const visible = (pts) => {
      let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
      for (const [x, y] of pts) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
      return x1 >= vw.x0 && x0 <= vw.x1 && y1 >= vw.y0 && y0 <= vw.y1;
    };
    this.visible = visible;

    for (const p of this.platOrder) this.drawPlatform(p, t);
    for (const b of this.order) if (visible(b.hull)) this.drawShadow(b);

    const styled = [];
    for (const b of this.order) {
      if (!visible(b.hull)) continue;
      const s = this.style(b, t);
      styled.push([b, s]);
      drawPad(ctx, b, s);
    }
    this.drawBelts(t, z);
    for (const [b, s] of styled) {
      if (b.node.status === "down") drawPadRing(ctx, b, "#ff4d4d", 0.5 + 0.4 * Math.sin(t * 4), 2.5);
      else if (b.node.status === "blocked") drawPadRing(ctx, b, "#ff9f1c", 0.75, 2);
      drawBuilding(ctx, b, s);
      if (b.node.container || b.node.inside) drawFittings(ctx, b, s);
      drawLamp(ctx, b, s);
    }
    this.drawPower(t, z);
    for (const [b, s] of styled) this.drawEffects(b, s, t);

    // The issues lens (missions.js): everything under a veil, then only the
    // buildings with an undone objective drawn again on top of it, ringed.
    if (this.focus && this.focus.size) {
      ctx.save();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.fillStyle = "rgba(4, 7, 15, 0.74)";
      ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
      ctx.restore();
      const pulse = 0.55 + 0.4 * Math.sin(t * 3);
      for (const [b, s] of styled) {
        const sev = this.focus.get(b.node.id);
        if (!sev) continue;
        drawPad(ctx, b, s);
        drawPadRing(ctx, b, sev === "alert" ? "#ff5a5a" : "#ffb347", pulse, 3);
        drawBuilding(ctx, b, s);
        if (b.node.container || b.node.inside) drawFittings(ctx, b, s);
        drawLamp(ctx, b, s);
      }
    }

    const sel = this.selected && this.world.nodes.get(this.selected);
    if (sel) drawPadRing(ctx, sel, "#7fe0ff", 0.95, 2.5);
    if (this.flash && tMs < this.flash.until) {
      const fb = this.world.nodes.get(this.flash.id);
      if (fb) {
        const k = (this.flash.until - tMs) / 1600;
        drawPadRing(ctx, fb, "#ffffff", k, 2 + 6 * (1 - k));
      }
    }
    const hov = this.hover && this.hover !== this.selected && this.world.nodes.get(this.hover);
    if (hov) drawPadRing(ctx, hov, "#cfd8ea", 0.5, 1.5);
  }

  style(b, t) {
    const n = b.node;
    const st = n.status;
    const tn = st === "unknown" ? tone("muted") : st === "down" ? tone("charred") : tone();
    let load = 0;
    const host = this.snap.host;
    if (n.load !== undefined) load = isNum(n.load) ? Math.max(0, Math.min(1, n.load)) : 0;
    else if (n.id === "host-cpu") load = isNum(host.cpu_used_cores) && host.cores ? host.cpu_used_cores / host.cores : 0;
    else if (n.id === "host-mem") load = isNum(host.mem_used_bytes) && host.mem_total_bytes ? host.mem_used_bytes / host.mem_total_bytes : 0;
    else if (n.id === "host-disk") load = isNum(host.disk_used_bytes) && host.disk_total_bytes ? host.disk_used_bytes / host.disk_total_bytes : 0;
    else if (n.container && isNum(n.container.cpu_cores)) load = Math.min(1, n.container.cpu_cores);
    const c = n.container;
    let memFrac = null, memLimited = false;
    if (c && isNum(c.mem_bytes)) {
      if (isNum(c.mem_limit_bytes) && c.mem_limit_bytes > 0) { memFrac = c.mem_bytes / c.mem_limit_bytes; memLimited = true; }
      else if (isNum(host.mem_total_bytes) && host.mem_total_bytes > 0) memFrac = c.mem_bytes / host.mem_total_bytes;
    }
    const flights = (n.hosts ?? []).map((h) => h.in_flight).filter(isNum);
    let containers = null;
    if (n.kind === "db") {
      const plan = containerPlan(n.holds);
      containers = [];
      plan.counts.forEach((k, i) => { for (let j = 0; j < k; j++) containers.push(HOLD_COLORS[i % HOLD_COLORS.length]); });
    }
    const unitsInside = n.inside?.ok ? (n.inside.units ?? []).reduce((a, x) => a + (isNum(x.count) ? x.count : 0), 0) : null;
    return {
      unitsInside,
      memFrac, memLimited, inFlight: flights.reduce((a, v) => a + v, 0), containers,
      col: tn, t: t + (b.seed % 1000) / 137, status: st, on: st === "working" || (st === "blocked" && n.kind !== "resource"),
      load, accent: b.accent, seed: b.seed,
      holdColors: n.holds?.length ? n.holds.map((_, i) => HOLD_COLORS[i % HOLD_COLORS.length]) : [],
      bytes: n.holds?.[0]?.bytes,
    };
  }

  drawPlatform(p, t) {
    const { ctx } = this;
    const corners = [P(p.x, p.y), P(p.x + p.w, p.y), P(p.x + p.w, p.y + p.d), P(p.x, p.y + p.d)];
    const deep = 0.9;
    // inside a building the plating is a different metal, so it never reads as the main floor
    const base = p.unplaced ? "#3f4656" : this.theme === "inside" ? "#3d5560" : "#4b5366";
    if (!this.visible([...corners, P(p.x + p.w, p.y + p.d, -deep)])) return;
    // underside thrusters
    if (!p.unplaced) {
      for (const [ux, uy] of [[p.x + p.w * 0.2, p.y + p.d], [p.x + p.w, p.y + p.d * 0.25], [p.x + p.w * 0.8, p.y + p.d]]) {
        const [jx, jy] = P(ux, uy, -deep);
        const flick = 0.75 + 0.25 * Math.sin(t * 13 + ux);
        const g = ctx.createLinearGradient(jx, jy, jx, jy + 70 * flick);
        g.addColorStop(0, "rgba(140,220,255,0.75)");
        g.addColorStop(1, "rgba(140,220,255,0)");
        ctx.fillStyle = g;
        ctx.beginPath(); ctx.moveTo(jx - 7, jy); ctx.lineTo(jx + 7, jy); ctx.lineTo(jx, jy + 70 * flick); ctx.closePath(); ctx.fill();
      }
    }
    // slab sides
    poly(ctx, [P(p.x, p.y + p.d), P(p.x + p.w, p.y + p.d), P(p.x + p.w, p.y + p.d, -deep), P(p.x, p.y + p.d, -deep)], shade("#2c3240", 1));
    poly(ctx, [P(p.x + p.w, p.y), P(p.x + p.w, p.y + p.d), P(p.x + p.w, p.y + p.d, -deep), P(p.x + p.w, p.y, -deep)], shade("#232834", 1));
    // side lamps
    for (let i = 2; i < p.w; i += 4) {
      const [lx, ly] = P(p.x + i, p.y + p.d, -deep * 0.45);
      glow(ctx, lx, ly, 7, "#ffb347", 0.55);
    }
    for (let i = 2; i < p.d; i += 4) {
      const [lx, ly] = P(p.x + p.w, p.y + i, -deep * 0.45);
      glow(ctx, lx, ly, 7, "#ffb347", 0.45);
    }
    // floor
    poly(ctx, corners, base);
    // worn plating: fixed blotches, lighter and darker, so the floor is not flat
    if (!p.blots) {
      let seed = hashStr(p.id) || 1;
      const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
      p.blots = [];
      const n = Math.min(260, Math.round((p.w * p.d) / 7));
      for (let i = 0; i < n; i++) p.blots.push([p.x + 1 + rnd() * (p.w - 2), p.y + 1 + rnd() * (p.d - 2), 14 + rnd() * 34, rnd()]);
    }
    for (const [bx, by, r, k] of p.blots) {
      const [sx, sy] = P(bx, by);
      ctx.beginPath(); ctx.ellipse(sx, sy, r, r * 0.5, 0, 0, Math.PI * 2);
      ctx.fillStyle = k > 0.5 ? "rgba(255,255,255,0.025)" : "rgba(10,12,20,0.07)";
      ctx.fill();
    }
    // tiles
    ctx.beginPath();
    for (let i = 1; i < p.w; i++) { ctx.moveTo(...P(p.x + i, p.y)); ctx.lineTo(...P(p.x + i, p.y + p.d)); }
    for (let j = 1; j < p.d; j++) { ctx.moveTo(...P(p.x, p.y + j)); ctx.lineTo(...P(p.x + p.w, p.y + j)); }
    ctx.strokeStyle = "rgba(20,24,34,0.28)"; ctx.lineWidth = 0.7; ctx.stroke();
    // hazard border
    ctx.save();
    ctx.beginPath(); corners.forEach((c, i) => (i ? ctx.lineTo(...c) : ctx.moveTo(...c))); ctx.closePath();
    ctx.strokeStyle = "#1a1d24"; ctx.lineWidth = 3.4; ctx.stroke();
    if (p.unplaced) { ctx.setLineDash([8, 6]); ctx.strokeStyle = "#8b93a7"; ctx.lineWidth = 1.6; }
    else { ctx.setLineDash([6, 6]); ctx.strokeStyle = this.theme === "inside" ? "#4cc9f0" : "#e0ad2a"; ctx.lineWidth = 3.4; }
    ctx.stroke();
    ctx.restore();
    // painted label along the front-left edge
    ctx.save();
    const a = P(p.x + 0.6, p.y + p.d - 0.6);
    ctx.translate(a[0], a[1]);
    // map text x to world +x direction (screen (32,16) per tile), text y to world +y
    ctx.transform(TW / 32, TH / 32, -TW / 32, TH / 32, 0, 0);
    ctx.font = "800 30px system-ui, sans-serif";
    ctx.fillStyle = "rgba(225,232,245,0.2)";
    ctx.textBaseline = "bottom";
    ctx.fillText(p.label.toUpperCase(), 0, 0);
    ctx.restore();
  }

  drawBelts(t, z) {
    const { ctx } = this;
    const W = 0.42;
    const items = [];
    for (const r of this.routes.values()) {
      const e = r.edge;
      const pts = r.pts;
      const proj = pts.map(([x, y]) => P(x, y, 0.12));
      if (!this.visible(proj)) continue;
      const unknown = e.metered && e.rate == null;
      const dashed = !e.metered;
      const col = itemColor(e.item);
      // body
      for (let i = 1; i < pts.length; i++) {
        const [ax, ay] = pts[i - 1], [bx, by] = pts[i];
        const h = W / 2;
        let q;
        if (ay === by) { const x0 = Math.min(ax, bx) - h, x1 = Math.max(ax, bx) + h; q = [[x0, ay - h], [x1, ay - h], [x1, ay + h], [x0, ay + h]]; }
        else { const y0 = Math.min(ay, by) - h, y1 = Math.max(ay, by) + h; q = [[ax - h, y0], [ax + h, y0], [ax + h, y1], [ax - h, y1]]; }
        const qp = q.map(([x, y]) => P(x, y, 0.1));
        if (!dashed) {
          poly(ctx, q.map(([x, y]) => P(x, y, 0.0)), "#151820");
        }
        poly(ctx, qp, dashed ? "rgba(30,34,44,0.55)" : "#262b36");
      }
      // rails: a glowing line down each side of the belt, in the colour of
      // whoever the belt feeds (requests) or of the item it carries
      const target = this.world.nodes.get(e.to);
      const rail = e.item === "requests" && e.from !== "internet" && target ? target.accent : col;
      ctx.save();
      ctx.lineCap = "round"; ctx.lineJoin = "round";
      ctx.beginPath();
      proj.forEach((p, i) => (i ? ctx.lineTo(...p) : ctx.moveTo(...p)));
      if (dashed) {
        ctx.setLineDash([5, 6]);
        ctx.strokeStyle = alpha(col, 0.55); ctx.lineWidth = 1.6; ctx.stroke();
      } else if (unknown) {
        ctx.strokeStyle = "rgba(160,168,186,0.55)"; ctx.lineWidth = 1.4; ctx.stroke();
      } else {
        const lit = e.rate > 0;
        if (lit) { ctx.strokeStyle = alpha(rail, 0.16); ctx.lineWidth = 19; ctx.stroke(); }
        ctx.strokeStyle = alpha(rail, lit ? 0.95 : 0.3); ctx.lineWidth = 12.5; ctx.stroke();
        ctx.strokeStyle = "#1b1f29"; ctx.lineWidth = 9.5; ctx.stroke();
      }
      ctx.restore();
      if (dashed) continue;
      // items
      if (unknown) {
        // We do not know if anything moves: hollow, still markers.
        for (let s = 0.8; s < r.len - 0.4; s += 1.6) items.push([r, s, null]);
        continue;
      }
      if (!(e.rate > 0)) continue;
      const m = beltMotion(e.rate);
      const travelled = t * m.speed;
      const phase = ((travelled % m.spacing) + m.spacing) % m.spacing;
      // Each item keeps its number as it rides, so its colour does not flicker.
      const first = Math.floor(travelled / m.spacing);
      const mix = classMix(e.codes);
      let j = 0;
      for (let s = phase; s < r.len; s += m.spacing, j++) {
        items.push([r, s, mix ? classOf(mix, hashStr(`${e.id}#${first - j}`)) : col]);
      }
    }
    // draw items after all bodies so crossings do not hide them
    const small = z < 0.35;
    for (const [r, s, col] of items) {
      const [x, y] = along(r.pts, s);
      const [px, py] = P(x, y, 0.16);
      if (col == null) {
        ctx.beginPath(); ctx.arc(px, py - 2, 2.6, 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(190,198,214,0.6)"; ctx.lineWidth = 1; ctx.stroke();
        continue;
      }
      if (small) { ctx.fillStyle = col; ctx.fillRect(px - 2.5, py - 3, 5, 3); continue; }
      glow(ctx, px, py - 5, 11, col, 0.3);
      const k = 0.13;
      poly(ctx, [P(x - k, y - k, 0.32), P(x + k, y - k, 0.32), P(x + k, y + k, 0.32), P(x - k, y + k, 0.32)], shade(col, 1.15));
      poly(ctx, [P(x - k, y + k, 0.16), P(x + k, y + k, 0.16), P(x + k, y + k, 0.32), P(x - k, y + k, 0.32)], shade(col, 0.85));
      poly(ctx, [P(x + k, y - k, 0.16), P(x + k, y + k, 0.16), P(x + k, y + k, 0.32), P(x + k, y - k, 0.32)], shade(col, 0.62));
    }
  }

  // One line from host-cpu and one from host-mem to every node with a container.
  drawPower(t, z) {
    const { ctx } = this;
    const host = this.snap.host;
    const srcs = [
      ["host-cpu", CPU_COLOR, (c) => (isNum(c.cpu_cores) && host.cores ? c.cpu_cores / host.cores : null)],
      ["host-mem", MEM_COLOR, (c) => (isNum(c.mem_bytes) && host.mem_total_bytes ? c.mem_bytes / host.mem_total_bytes : null)],
    ];
    const anySel = !!this.selected;
    ctx.save();
    ctx.lineCap = "round";
    for (const [sid, col, frac] of srcs) {
      const sb = this.world.nodes.get(sid);
      if (!sb) continue;
      const from = P(sb.x + 2.7, sb.y + 0.6, sid === "host-cpu" ? 2.3 : 2.1);
      const off = sid === "host-cpu" ? -10 : 10;
      for (const b of this.order) {
        const c = b.node.container;
        if (!c) continue;
        const to = P(b.x + 1.5, b.y + 1.5, b.h + 0.05);
        const mid = [(from[0] + to[0]) / 2 + off, Math.min(from[1], to[1]) - 50 - Math.hypot(to[0] - from[0], to[1] - from[1]) * 0.12];
        if (!this.visible([from, to, mid])) continue;
        const f = frac(c);
        const mine = this.selected === b.node.id || this.selected === sid;
        const dim = anySel && !mine ? 0.3 : 1;
        ctx.beginPath(); ctx.moveTo(...from); ctx.quadraticCurveTo(mid[0], mid[1], ...to);
        if (f == null) {
          ctx.setLineDash([2, 5]); ctx.strokeStyle = `rgba(150,158,176,${0.45 * dim})`; ctx.lineWidth = 0.9; ctx.stroke(); ctx.setLineDash([]);
          continue;
        }
        const k = Math.sqrt(Math.min(1, f));
        const lw = (0.8 + 5 * k) * (mine ? 1.6 : 1);
        ctx.strokeStyle = alpha(col, Math.min(1, (0.34 + 0.55 * k) * dim * (mine ? 1.8 : 1)));
        ctx.lineWidth = lw; ctx.stroke();
        if (this.motion) {
          ctx.setLineDash([6, 34]);
          ctx.lineDashOffset = -t * (25 + 400 * k);
          ctx.strokeStyle = alpha("#ffffff", Math.min(1, (0.25 + 0.6 * k) * dim));
          ctx.lineWidth = Math.max(0.8, lw * 0.7); ctx.stroke();
          ctx.setLineDash([]);
        }
      }
    }
    ctx.restore();
    // pylon caps on consumers
    for (const b of this.order) {
      if (!b.node.container) continue;
      const [x, y] = P(b.x + 1.5, b.y + 1.5, b.h + 0.05);
      ctx.beginPath(); ctx.arc(x, y, 2, 0, Math.PI * 2); ctx.fillStyle = "#c9cfdb"; ctx.fill();
    }
  }

  drawShadow(b) {
    const { ctx } = this;
    const [sx, sy] = P(b.x + 1.9, b.y + 1.9, 0.1);
    ctx.save();
    ctx.translate(sx + 14, sy + 4); ctx.scale(1, 0.5);
    const g = ctx.createRadialGradient(0, 0, 8, 0, 0, 84);
    g.addColorStop(0, "rgba(8,10,18,0.36)"); g.addColorStop(1, "rgba(8,10,18,0)");
    ctx.fillStyle = g;
    ctx.beginPath(); ctx.arc(0, 0, 84, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
  }

  drawEffects(b, s, t) {
    const { ctx } = this;
    const st = b.node.status;
    if (st === "down") return this.drawFire(b, t);
    if (!s.on) return;
    for (const [cx, cy] of chimneys(b)) {
      for (let i = 0; i < 6; i++) {
        const age = this.motion ? (t * 0.25 + i / 6 + (b.seed % 7) / 7) % 1 : i / 6;
        const r = 3 + age * 13;
        ctx.beginPath();
        ctx.arc(cx + age * 22 + Math.sin(age * 5 + i) * 3, cy - age * 60, r, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(205,210,220,${0.22 * (1 - age)})`;
        ctx.fill();
      }
    }
  }

  drawFire(b, t) {
    const { ctx } = this;
    const [gx, gy] = P(b.x + 1.5, b.y + 1.5, 0.1);
    glow(ctx, gx, gy, 90, "#ff5a1f", 0.28 + 0.08 * Math.sin(t * 7));
    // smoke column
    const [sx, sy] = P(b.x + 1.5, b.y + 1.5, b.h);
    for (let i = 0; i < 12; i++) {
      const age = this.motion ? (t * 0.22 + i / 12) % 1 : i / 12;
      const r = 6 + age * 34;
      ctx.beginPath();
      ctx.arc(sx + age * 46 + Math.sin(age * 4 + i) * 6, sy - 10 - age * 150, r, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(42,40,46,${0.42 * (1 - age)})`;
      ctx.fill();
    }
    // flames
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    const spots = [[1.5, 1.5, b.h * 0.85, 1.25], [0.7, 2.2, b.h * 0.5, 0.8], [2.3, 1.0, b.h * 0.6, 0.9], [2.4, 2.5, 0.15, 0.7], [0.5, 0.8, 0.4, 0.6]];
    spots.forEach(([fx, fy, fz, sc], i) => {
      const [px, py] = P(b.x + fx, b.y + fy, fz);
      for (let k = 0; k < 3; k++) {
        const fl = this.motion ? 0.75 + 0.25 * Math.sin(t * (11 + k * 3) + i * 2.1 + k) : 0.9;
        const hgt = (26 - k * 7) * sc * fl, wid = (9 - k * 2) * sc;
        const g = ctx.createLinearGradient(px, py, px, py - hgt);
        g.addColorStop(0, k === 2 ? "rgba(255,250,200,0.95)" : "rgba(255,120,20,0.85)");
        g.addColorStop(0.6, k === 2 ? "rgba(255,210,80,0.7)" : "rgba(255,70,10,0.5)");
        g.addColorStop(1, "rgba(255,40,0,0)");
        ctx.fillStyle = g;
        const sway = this.motion ? Math.sin(t * 5 + i + k) * 3 * sc : 0;
        ctx.beginPath();
        ctx.moveTo(px - wid, py);
        ctx.quadraticCurveTo(px - wid * 0.9, py - hgt * 0.5, px + sway, py - hgt);
        ctx.quadraticCurveTo(px + wid * 0.9, py - hgt * 0.5, px + wid, py);
        ctx.closePath();
        ctx.fill();
      }
    });
    ctx.restore();
  }
}

// Cumulative shares of a belt's status classes, or null when there is nothing
// to colour by (codes unknown, or nothing counted yet).
function classMix(codes) {
  if (!codes) return null;
  const total = CLASS_ORDER.reduce((a, k) => a + (isNum(codes[k]) ? codes[k] : 0), 0);
  if (!(total > 0)) return null;
  let acc = 0;
  return CLASS_ORDER.map((k) => [(acc += (isNum(codes[k]) ? codes[k] : 0) / total), CLASS_COLOR[k]]);
}
function classOf(mix, h) {
  const u = (h % 10007) / 10007;
  for (const [edge, col] of mix) if (u < edge) return col;
  return mix[mix.length - 1][1];
}

export function clampZoom(z) { return Math.max(0.12, Math.min(3, z)); }

function along(pts, s) {
  for (let i = 1; i < pts.length; i++) {
    const [ax, ay] = pts[i - 1], [bx, by] = pts[i];
    const l = Math.abs(bx - ax) + Math.abs(by - ay);
    if (s <= l || i === pts.length - 1) {
      const f = l ? Math.min(1, s / l) : 0;
      return [ax + (bx - ax) * f, ay + (by - ay) * f];
    }
    s -= l;
  }
  return pts[pts.length - 1];
}

export { STATUS_COLOR, ZH };
