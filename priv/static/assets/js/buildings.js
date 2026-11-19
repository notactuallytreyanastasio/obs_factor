// One procedural building per `kind`. Every drawer works in tiles on a
// FOOT x FOOT footprint at (b.x, b.y) and gets a style `s`:
//   s.col(hex, f)  colour tone (normal / muted for unknown / charred for down)
//   s.t            seconds, frozen when motion is reduced
//   s.on           true when the building is doing something (status working)
//   s.load         0..1, how hard it works (drives fans, flywheels)
//   s.accent       per-node colour
//   s.holdColors   colours of the HOLDS keys, for db bands

import { P, box, cyl, faceX, faceY, poly, line, glow, alpha, shade, ZH } from "./iso.js";

export const STATUS_COLOR = {
  working: "#3ddc84", idle: "#f2c94c", blocked: "#ff9f1c", down: "#ff4d4d", unknown: "#8b93a7",
};

// Top of each silhouette (tiles of z): chips and power lines attach here.
export const HEIGHT = {
  proxy: 2.4, app: 2.5, relay: 3.4, db: 2.2, static: 1.6, external: 2.3,
  resource: 2.7, source: 3.0, unplaced: 1.5,
};

const WIN_ON = "#ffcf70", WIN_OFF = "#2a3142";

export function drawPad(ctx, b, s) {
  const { x, y } = b;
  const e = 0.18;
  box(ctx, s.col, x - e, y - e, 0, 3 + 2 * e, 3 + 2 * e, 0.1, "#a3acbd");
  // edge markings on the two visible edges
  const a = P(x - e, y + 3 + e, 0.1), c = P(x + 3 + e, y + 3 + e, 0.1), d = P(x + 3 + e, y - e, 0.1);
  ctx.save();
  ctx.lineCap = "butt";
  if (s.status === "unknown") {
    ctx.setLineDash([3, 4]);
    ctx.beginPath(); ctx.moveTo(...a); ctx.lineTo(...c); ctx.lineTo(...d);
    ctx.strokeStyle = "#9aa3b8"; ctx.lineWidth = 1.6; ctx.stroke();
  } else {
    ctx.beginPath(); ctx.moveTo(...a); ctx.lineTo(...c); ctx.lineTo(...d);
    ctx.strokeStyle = s.status === "down" ? "#3a1d1d" : "#1c1f26"; ctx.lineWidth = 2.6; ctx.stroke();
    ctx.setLineDash([4, 4]);
    ctx.strokeStyle = s.status === "down" ? "#7a3a2a" : "#e8b730"; ctx.stroke();
  }
  ctx.restore();
}

// Ring glowing around the pad: selection (cyan), blocked (amber), down (red).
export function drawPadRing(ctx, b, hex, a = 0.9, width = 2) {
  const e = 0.3;
  const pts = [P(b.x - e, b.y - e, 0.12), P(b.x + 3 + e, b.y - e, 0.12), P(b.x + 3 + e, b.y + 3 + e, 0.12), P(b.x - e, b.y + 3 + e, 0.12)];
  ctx.save();
  ctx.shadowColor = hex; ctx.shadowBlur = 10;
  poly(ctx, pts, null, alpha(hex, a), width);
  ctx.restore();
}

export function drawLamp(ctx, b, s) {
  const lx = b.x + 3.05, ly = b.y + 0.15;
  const base = P(lx, ly, 0.1), top = P(lx, ly, 1.25);
  line(ctx, base, top, "#2b2f3a", 1.6);
  const hex = STATUS_COLOR[s.status] ?? STATUS_COLOR.unknown;
  if (s.status === "unknown") {
    // Not "fine": a hollow, dashed lamp with a question mark.
    ctx.save();
    ctx.setLineDash([2, 2]);
    ctx.beginPath(); ctx.arc(top[0], top[1] - 4, 5.5, 0, Math.PI * 2);
    ctx.strokeStyle = "#c3c9d8"; ctx.lineWidth = 1.4; ctx.stroke();
    ctx.restore();
    ctx.fillStyle = "#d6dbe6"; ctx.font = "bold 7px system-ui, sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
    ctx.fillText("?", top[0], top[1] - 3.6);
    return;
  }
  let a = 0.75;
  if (s.status === "down") a = 0.35 + 0.65 * (Math.sin(s.t * 6) > 0 ? 1 : 0.2);
  if (s.status === "blocked") a = 0.55 + 0.4 * Math.sin(s.t * 3);
  glow(ctx, top[0], top[1] - 4, 16, hex, 0.55 * a);
  ctx.beginPath(); ctx.arc(top[0], top[1] - 4, 3.6, 0, Math.PI * 2);
  ctx.fillStyle = shade(hex, 0.6 + 0.6 * a); ctx.fill();
}

// ---- kinds ----------------------------------------------------------------

function app(ctx, b, s) {
  const { x, y } = b, c = s.col;
  // chimney behind the hall
  cyl(ctx, c, x + 0.7, y + 0.35, 0.1, 0.22, 2.35, "#7c4a36", {
    bands: [[1.9, 2.05, c("#e2e6ee")], [2.15, 2.25, c("#c0392b")]], hollow: "#1a1a1a",
  });
  const xa = x + 0.25, xb = x + 2.5, ya = y + 0.65, yb = y + 2.75;
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 1.0, "#7a8496");
  // windows
  const win = s.on ? WIN_ON : c(WIN_OFF);
  for (let i = 0; i < 5; i++) {
    const x0 = xa + 0.18 + i * 0.43;
    faceY(ctx, yb, x0, x0 + 0.28, 0.45, 0.78, win);
  }
  for (let i = 0; i < 4; i++) {
    const y0 = ya + 0.2 + i * 0.48;
    faceX(ctx, xb, y0, y0 + 0.3, 0.45, 0.78, i === 3 ? c("#3a3f4c") : win);
  }
  faceX(ctx, xb, ya + 1.55, ya + 1.95, 0.1, 0.62, c("#2b303b"));
  // sawtooth roof, back to front
  const teeth = 3, dy = (yb - ya) / teeth;
  for (let i = 0; i < teeth; i++) {
    const y0 = ya + i * dy, y1 = y0 + dy;
    poly(ctx, [P(xa, y0, 1.1), P(xb, y0, 1.1), P(xb, y1, 1.55), P(xa, y1, 1.55)], c("#59627a", 1.15));
    poly(ctx, [P(xb, y0, 1.1), P(xb, y1, 1.1), P(xb, y1, 1.55)], c("#59627a", 0.7));
    faceY(ctx, y1, xa, xb, 1.1, 1.55, s.on ? alpha("#9fe7ff", 0.85) : c("#46607a"));
  }
  // accent stripe along the front eave
  faceY(ctx, yb, xa, xb, 0.98, 1.1, c(s.accent));
  faceX(ctx, xb, ya, yb, 0.98, 1.1, c(s.accent, 0.7));
  // side tank
  cyl(ctx, c, x + 2.78, y + 2.55, 0.1, 0.2, 0.6, "#9aa4b5");
}

function proxy(ctx, b, s) {
  const { x, y } = b, c = s.col;
  // tower at the back with an antenna
  box(ctx, c, x + 0.35, y + 0.35, 0.1, 0.85, 0.85, 2.0, "#6c768c");
  faceY(ctx, y + 1.2, x + 0.5, x + 1.05, 1.5, 1.75, s.on ? WIN_ON : c(WIN_OFF));
  faceX(ctx, x + 1.2, y + 0.5, y + 1.05, 1.5, 1.75, s.on ? WIN_ON : c(WIN_OFF));
  const ant0 = P(x + 0.78, y + 0.78, 2.1), ant1 = P(x + 0.78, y + 0.78, 2.9);
  line(ctx, ant0, ant1, c("#2b2f3a"), 1.4);
  const blink = 0.5 + 0.5 * Math.sin(s.t * 4);
  glow(ctx, ant1[0], ant1[1], 9, "#ff5a5a", 0.5 * blink);
  // hall with two gates
  const xa = x + 0.3, xb = x + 2.75, ya = y + 1.3, yb = y + 2.75;
  box(ctx, c, x + 1.3, y + 0.3, 0.1, xb - x - 1.3, 1.0, 0.95, "#79849a");
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 0.95, "#848fa5");
  const gate = s.on ? "#ffd166" : c("#3a4050");
  faceY(ctx, yb, x + 0.95, x + 1.95, 0.1, 0.72, c("#1d2129"));
  faceY(ctx, yb, x + 1.05, x + 1.85, 0.1, 0.62, s.on ? alpha("#ffd166", 0.35 + 0.25 * Math.sin(s.t * 2)) : c("#262b35"));
  faceX(ctx, xb, y + 0.65, y + 1.65, 0.1, 0.72, c("#1d2129"));
  faceX(ctx, xb, y + 0.75, y + 1.55, 0.1, 0.62, s.on ? alpha("#ffd166", 0.35 + 0.25 * Math.sin(s.t * 2 + 1)) : c("#262b35"));
  // hazard band
  faceY(ctx, yb, xa, xb, 0.85, 0.95, c("#e8b730"));
  faceX(ctx, xb, y + 0.3, yb, 0.85, 0.95, c("#e8b730", 0.75));
  // rotating dish on the roof
  const [dx, dy] = P(x + 2.0, y + 2.0, 1.4);
  const ang = s.t * 0.9;
  line(ctx, P(x + 2.0, y + 2.0, 1.05), [dx, dy], c("#2b2f3a"), 1.5);
  ctx.beginPath();
  ctx.ellipse(dx, dy, 13, 6, ang % Math.PI - Math.PI / 2, 0, Math.PI * 2);
  ctx.fillStyle = c("#d9dee8"); ctx.fill();
  ctx.strokeStyle = c("#7d8597"); ctx.lineWidth = 1; ctx.stroke();
  void gate;
}

function relay(ctx, b, s) {
  const { x, y } = b, c = s.col;
  // lattice mast
  const legs = [[x + 0.45, y + 0.45], [x + 1.55, y + 0.45], [x + 1.55, y + 1.55], [x + 0.45, y + 1.55]];
  const apex = [x + 1.0, y + 1.0];
  const H = 3.3;
  const at = (l, f) => P(l[0] + (apex[0] - l[0]) * f * 0.8, l[1] + (apex[1] - l[1]) * f * 0.8, 0.1 + f * H);
  ctx.lineWidth = 1.3;
  ctx.strokeStyle = c("#e0a526");
  ctx.beginPath();
  for (const l of legs) { const a = at(l, 0), z = at(l, 1); ctx.moveTo(...a); ctx.lineTo(...z); }
  for (let i = 0; i < 6; i++) {
    const f0 = i / 6, f1 = (i + 1) / 6;
    for (let k = 0; k < 4; k++) {
      const l0 = legs[k], l1 = legs[(k + 1) % 4];
      ctx.moveTo(...at(l0, f0)); ctx.lineTo(...at(l1, f1));
      ctx.moveTo(...at(l0, f1)); ctx.lineTo(...at(l1, f1));
    }
  }
  ctx.stroke();
  // dish on the mast
  const [mx, my] = at(legs[2], 0.62);
  ctx.beginPath(); ctx.ellipse(mx + 4, my, 9, 12, -0.4, 0, Math.PI * 2);
  ctx.fillStyle = c("#dfe3ea"); ctx.fill();
  ctx.strokeStyle = c("#8d95a6"); ctx.lineWidth = 1; ctx.stroke();
  // beacon
  const top = at(legs[0], 1);
  const blink = s.on ? 0.5 + 0.5 * Math.sin(s.t * 5) : 0.25;
  glow(ctx, top[0], top[1] - 3, 14, s.accent, 0.8 * blink);
  ctx.beginPath(); ctx.arc(top[0], top[1] - 3, 2.6, 0, Math.PI * 2); ctx.fillStyle = shade(s.accent, 0.8 + blink * 0.6); ctx.fill();
  // hut
  box(ctx, c, x + 1.7, y + 1.6, 0.1, 1.1, 1.15, 0.7, "#5f6f86");
  faceY(ctx, y + 2.75, x + 1.9, x + 2.2, 0.1, 0.55, c("#2a2f3b"));
  faceX(ctx, x + 2.8, y + 1.8, y + 2.3, 0.35, 0.55, s.on ? alpha("#9fe7ff", 0.9) : c(WIN_OFF));
  line(ctx, P(x + 1.55, y + 1.55, 1.6), P(x + 2.2, y + 2.2, 0.8), c("#1d2129"), 1);
}

function db(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const colors = s.holdColors.length ? s.holdColors : ["#5aa9e6"];
  const silo = (sx, sy, k) => {
    const bands = [];
    const n = Math.min(4, colors.length);
    for (let i = 0; i < n; i++) bands.push([0.35 + i * 0.32, 0.55 + i * 0.32, c(colors[(i + k) % colors.length], 0.9)]);
    cyl(ctx, c, sx, sy, 0.1, 0.55, 1.75, "#c9ced8", { bands });
    // domed top
    const [tx, ty] = P(sx, sy, 1.85);
    ctx.beginPath(); ctx.ellipse(tx, ty, 0.55 * 45.25, 0.55 * 22.6, 0, Math.PI, 0); ctx.ellipse(tx, ty, 0.55 * 45.25, 9, 0, 0, Math.PI, true);
    ctx.fillStyle = c("#e4e8ef"); ctx.fill();
    // ladder
    line(ctx, P(sx + 0.39, sy + 0.39, 0.1), P(sx + 0.39, sy + 0.39, 1.85), c("#e8b730"), 1);
  };
  silo(x + 0.75, y + 0.75, 0);
  // pipe bridge
  ctx.lineCap = "round";
  line(ctx, P(x + 0.75, y + 0.75, 1.4), P(x + 2.25, y + 0.75, 1.4), c("#8a5a3c"), 3);
  line(ctx, P(x + 0.75, y + 0.75, 1.4), P(x + 0.75, y + 2.25, 1.4), c("#8a5a3c"), 3);
  silo(x + 2.25, y + 0.75, 1);
  silo(x + 0.75, y + 2.25, 2);
  // pump house
  box(ctx, c, x + 1.7, y + 1.7, 0.1, 1.1, 1.1, 0.75, "#56627a");
  faceY(ctx, y + 2.8, x + 1.9, x + 2.6, 0.5, 0.65, s.on ? alpha("#4cc9f0", 0.9) : c(WIN_OFF));
  faceX(ctx, x + 2.8, y + 1.9, y + 2.6, 0.1, 0.6, c("#2b303b"));
  const [px, py] = P(x + 2.25, y + 2.25, 0.85);
  glow(ctx, px, py, 10, "#4cc9f0", s.on ? 0.35 + 0.2 * Math.sin(s.t * 3) : 0.08);
}

function staticSite(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const xa = x + 0.25, xb = x + 2.05, ya = y + 0.25, yb = y + 2.75;
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 1.1, "#8c8173");
  // roller doors on the +x face
  for (const y0 of [ya + 0.35, ya + 1.35]) {
    faceX(ctx, xb, y0, y0 + 0.75, 0.1, 0.8, c("#434a58"));
    for (let k = 1; k < 5; k++) line(ctx, P(xb, y0, 0.1 + k * 0.14), P(xb, y0 + 0.75, 0.1 + k * 0.14), c("#2d323d"), 0.6);
  }
  faceY(ctx, yb, xa + 0.3, xb - 0.3, 0.55, 0.85, s.on ? WIN_ON : c(WIN_OFF));
  // roof vents
  box(ctx, c, xa + 0.3, ya + 0.4, 1.2, 0.35, 0.35, 0.22, "#6d7487");
  box(ctx, c, xa + 0.3, ya + 1.4, 1.2, 0.35, 0.35, 0.22, "#6d7487");
  // crates on the apron: more bytes, more crates (log scale)
  const n = Math.max(1, Math.min(9, Math.round(Math.log10(Math.max(1, s.bytes ?? 1)) - 4)));
  const palette = ["#c97c3a", "#4a8fd6", "#5fb45a", "#d65a8f", "#d9b23a"];
  let k = 0;
  for (let row = 0; row < 3 && k < n; row++) {
    for (let col = 0; col < 2 && k < n; col++) {
      for (let lvl = 0; lvl < 2 && k < n; lvl++, k++) {
        box(ctx, c, x + 2.25 + col * 0.36, y + 0.4 + row * 0.75, 0.1 + lvl * 0.3, 0.32, 0.6, 0.3, palette[(k + s.seed) % palette.length]);
      }
    }
  }
}

function external(ctx, b, s) {
  const { x, y } = b, c = s.col;
  box(ctx, c, x + 0.4, y + 0.4, 0.1, 2.2, 2.2, 0.5, "#4f5a70");
  faceY(ctx, y + 2.6, x + 0.6, x + 2.4, 0.25, 0.4, alpha("#4cc9f0", 0.6));
  cyl(ctx, c, x + 1.5, y + 1.5, 0.6, 0.25, 0.75, "#9aa4b5");
  const [cx, cy] = P(x + 1.5, y + 1.5, 1.85);
  ctx.save();
  ctx.translate(cx, cy);
  ctx.rotate(-0.45);
  ctx.beginPath(); ctx.ellipse(0, 0, 40, 20, 0, 0, Math.PI * 2);
  const g = ctx.createRadialGradient(-6, -4, 2, 0, 0, 40);
  g.addColorStop(0, c("#f4f6fa")); g.addColorStop(1, c("#8f98aa"));
  ctx.fillStyle = g; ctx.fill();
  ctx.strokeStyle = c("#5c6476"); ctx.lineWidth = 1.2; ctx.stroke();
  ctx.beginPath(); ctx.moveTo(-18, 10); ctx.lineTo(0, -22); ctx.lineTo(18, 10);
  ctx.strokeStyle = c("#4b5263"); ctx.stroke();
  ctx.restore();
  glow(ctx, cx, cy - 22, 8, "#9fe7ff", 0.5);
}

function cpu(ctx, b, s) {
  const { x, y } = b, c = s.col;
  cyl(ctx, c, x + 0.6, y + 0.55, 0.1, 0.24, 2.6, "#8c4a2f", { bands: [[2.1, 2.25, c("#f0a040")]], hollow: "#1a1a1a" });
  cyl(ctx, c, x + 1.25, y + 0.45, 0.1, 0.2, 2.2, "#7a4430", { bands: [[1.8, 1.9, c("#f0a040")]], hollow: "#1a1a1a" });
  box(ctx, c, x + 0.25, y + 0.95, 0.1, 2.5, 1.8, 0.9, "#566078");
  faceY(ctx, y + 2.75, x + 0.4, x + 1.3, 0.35, 0.65, s.on ? WIN_ON : c(WIN_OFF));
  // flywheel standing on the +y face plane
  const cx = x + 2.0, cy = y + 2.95, cz = 0.85, r = 0.72;
  const pt = (a, rr = r) => P(cx + rr * Math.cos(a), cy, cz + rr * Math.sin(a));
  const ring = [];
  for (let i = 0; i < 24; i++) ring.push(pt((i / 24) * Math.PI * 2));
  poly(ctx, ring, c("#2a3040"), c("#c0703a"), 2.2);
  const rot = s.t * (0.5 + 6 * s.load);
  ctx.beginPath();
  for (let i = 0; i < 6; i++) {
    const a = rot + (i / 6) * Math.PI * 2;
    ctx.moveTo(...pt(a, 0.08)); ctx.lineTo(...pt(a, r * 0.95));
  }
  ctx.strokeStyle = c("#d79a5a"); ctx.lineWidth = 1.4; ctx.stroke();
  // lamp mast
  const m0 = P(x + 2.7, y + 0.6, 0.1), m1 = P(x + 2.7, y + 0.6, 2.3);
  line(ctx, m0, m1, c("#2b2f3a"), 2);
  glow(ctx, m1[0], m1[1], 16, "#ff8a3d", 0.35 + 0.5 * s.load);
  ctx.beginPath(); ctx.arc(m1[0], m1[1], 4, 0, Math.PI * 2); ctx.fillStyle = shade("#ff8a3d", 0.8 + 0.5 * s.load); ctx.fill();
}

function mem(ctx, b, s) {
  const { x, y } = b, c = s.col;
  box(ctx, c, x + 0.2, y + 0.3, 0.1, 2.6, 2.4, 0.25, "#3d4558");
  const fill = Math.max(0.05, Math.min(1, s.load));
  for (let i = 0; i < 4; i++) {
    for (let j = 0; j < 2; j++) {
      const bx = x + 0.4 + i * 0.6, by = y + 0.6 + j * 1.1;
      box(ctx, c, bx, by, 0.35, 0.42, 0.55, 1.7, "#2c3242");
      const lit = 0.4 + 1.2 * fill;
      faceY(ctx, by + 0.55, bx + 0.12, bx + 0.3, 0.5, 0.5 + 1.4 * fill, alpha("#8a9bff", 0.9));
      faceY(ctx, by + 0.55, bx + 0.12, bx + 0.3, 0.5 + 1.4 * fill, 1.9, c("#1b1f2a"));
      void lit;
    }
  }
  const [tx, ty] = P(x + 1.5, y + 1.5, 2.3);
  glow(ctx, tx, ty, 26, "#8a9bff", 0.25 + 0.3 * fill);
}

function disk(ctx, b, s) {
  const { x, y } = b, c = s.col;
  box(ctx, c, x + 0.2, y + 0.9, 0.1, 2.6, 1.6, 0.4, "#3b4252");
  const used = Math.max(0, Math.min(1, s.load));
  const liquid = s.status === "blocked" ? "#ff9f1c" : "#61e294";
  for (let i = 0; i < 4; i++) {
    const tx = x + 0.55 + i * 0.62, ty = y + 1.7;
    cyl(ctx, c, tx, ty, 0.5, 0.26, 1.7, "#b9c6d6", {
      bands: [[0.0, 1.55 * used, alpha(liquid, 0.85)]], top: c("#dfe7f2"),
    });
    cyl(ctx, c, tx, ty, 2.2, 0.15, 0.12, "#8c96a8");
  }
  line(ctx, P(x + 0.55, y + 1.7, 2.3), P(x + 2.4, y + 1.7, 2.3), c("#b87333"), 2.2);
}

function source(ctx, b, s) {
  const { x, y } = b, c = s.col;
  box(ctx, c, x + 0.3, y + 0.9, 0.1, 2.4, 1.3, 0.35, "#454f63");
  const cx = x + 1.5, cy = y + 1.55, cz = 1.75, r = 1.3;
  const pt = (a, rr) => P(cx + rr * Math.cos(a), cy, cz + rr * Math.sin(a));
  const outer = [], inner = [];
  for (let i = 0; i < 32; i++) { const a = (i / 32) * Math.PI * 2; outer.push(pt(a, r)); inner.push(pt(a, r * 0.78)); }
  // portal surface
  poly(ctx, inner, s.on ? alpha("#4cc9f0", 0.22 + 0.1 * Math.sin(s.t * 2)) : alpha("#7d8597", 0.15));
  if (s.on) {
    ctx.beginPath();
    for (let k = 0; k < 3; k++) {
      const a0 = s.t * 1.3 + (k * Math.PI * 2) / 3;
      for (let i = 0; i <= 14; i++) {
        const a = a0 + i * 0.25, rr = r * 0.75 * (1 - i / 16);
        const p = pt(a, rr);
        if (i === 0) ctx.moveTo(...p); else ctx.lineTo(...p);
      }
    }
    ctx.strokeStyle = alpha("#bdf3ff", 0.6); ctx.lineWidth = 1.2; ctx.stroke();
  }
  // ring
  ctx.beginPath();
  outer.forEach((p, i) => (i ? ctx.lineTo(...p) : ctx.moveTo(...p)));
  ctx.closePath();
  ctx.strokeStyle = c("#2d3444"); ctx.lineWidth = 9; ctx.stroke();
  ctx.strokeStyle = s.on ? "#7fe0ff" : c("#7d8597"); ctx.lineWidth = 2; ctx.stroke();
  for (let i = 0; i < 8; i++) {
    const p = pt((i / 8) * Math.PI * 2 + Math.PI / 8, r);
    ctx.beginPath(); ctx.arc(p[0], p[1], 2.4, 0, Math.PI * 2);
    ctx.fillStyle = s.on ? "#e8b730" : c("#5b6274"); ctx.fill();
  }
  // feet
  box(ctx, c, x + 0.45, y + 1.35, 0.1, 0.4, 0.4, 0.9, "#5a6377");
  box(ctx, c, x + 2.15, y + 1.35, 0.1, 0.4, 0.4, 0.9, "#5a6377");
}

function unplaced(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const xa = x + 0.3, xb = x + 2.7, ya = y + 0.8, yb = y + 2.2;
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 1.05, "#b8642a");
  ctx.beginPath();
  for (let k = 1; k < 12; k++) {
    const xx = xa + (k * (xb - xa)) / 12;
    ctx.moveTo(...P(xx, yb, 0.15)); ctx.lineTo(...P(xx, yb, 1.1));
  }
  ctx.strokeStyle = c("#7d3f17"); ctx.lineWidth = 0.8; ctx.stroke();
  faceX(ctx, xb, ya + 0.1, yb - 0.1, 0.15, 1.05, c("#9c5422"));
  line(ctx, P(xb, ya + 0.7, 0.15), P(xb, ya + 0.7, 1.05), c("#5e2e10"), 1);
  // stencil
  const [qx, qy] = P(xa + 1.2, yb, 0.62);
  ctx.save();
  ctx.translate(qx, qy); ctx.transform(1, -0.5, 0, 1, 0, 0);
  ctx.fillStyle = c("#f1e3c8"); ctx.font = "bold 15px system-ui, sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
  ctx.fillText("?", 0, 0);
  ctx.restore();
  box(ctx, c, x + 0.4, y + 2.35, 0.1, 0.5, 0.5, 0.4, "#8a7a5c");
}

export function drawBuilding(ctx, b, s) {
  const n = b.node;
  switch (n.kind) {
    case "app": return app(ctx, b, s);
    case "proxy": return proxy(ctx, b, s);
    case "relay": return relay(ctx, b, s);
    case "db": return db(ctx, b, s);
    case "static": return staticSite(ctx, b, s);
    case "external": return external(ctx, b, s);
    case "source": return source(ctx, b, s);
    case "unplaced": return unplaced(ctx, b, s);
    case "resource":
      if (n.id === "host-cpu") return cpu(ctx, b, s);
      if (n.id === "host-mem") return mem(ctx, b, s);
      return disk(ctx, b, s);
    default:
      // A kind this page does not know: draw a bare marked crate so it is
      // visible, and say what it is (the overlay names the kind).
      box(ctx, s.col, b.x + 0.6, b.y + 0.6, 0.1, 1.8, 1.8, 1.2, "#ff00aa");
      return;
  }
}

// Points where smoke leaves the building, for the effects pass.
export function chimneys(b) {
  const { x, y } = b;
  switch (b.node.kind) {
    case "app": return [P(x + 0.7, y + 0.35, 2.45)];
    case "resource": return b.node.id === "host-cpu" ? [P(x + 0.6, y + 0.55, 2.7), P(x + 1.25, y + 0.45, 2.3)] : [];
    default: return [];
  }
}

export { ZH };
