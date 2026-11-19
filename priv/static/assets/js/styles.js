// A building of its own for every subdomain. The snapshot's `style` names one
// of these (docs/contract.md, Per-subdomain detail); a node without a style,
// or with one this page does not know, gets the building of its `kind`.
//
// Same rules as buildings.js: tiles on a 3 x 3 footprint at (b.x, b.y), a
// style `s` with s.col (tone), s.t (seconds), s.on (working), s.load (0..1),
// s.accent. Things are drawn back to front: small x + y first.

import { P, TW, TH, ZH, box, cyl, faceX, faceY, poly, line, glow, alpha, shade } from "./iso.js";

const R2 = Math.SQRT2;
const WIN_ON = "#ffcf70", WIN_OFF = "#2a3142";

// Top of each silhouette, in tiles: chips and power lines attach here.
export const STYLE_HEIGHT = {
  press: 2.3, foundry: 3.0, switchyard: 2.4, studio: 2.5, library: 2.2, conservatory: 2.9,
  observatory: 2.5, control: 3.3, arena: 2.3, greenhouse: 2.6, arcade: 2.4, lab: 2.4, stage: 2.2,
};

// ---- helpers --------------------------------------------------------------

// Half-ellipsoid standing on z, axis at (cx, cy).
function dome(ctx, cx, cy, z, r, h, fill, stroke) {
  const [bx, by] = P(cx, cy, z);
  const rx = r * TW * R2, ry = r * TH * R2;
  ctx.beginPath();
  ctx.ellipse(bx, by, rx, h * ZH, 0, Math.PI, 0);
  ctx.ellipse(bx, by, rx, ry, 0, 0, Math.PI);
  ctx.closePath();
  if (fill) { ctx.fillStyle = fill; ctx.fill(); }
  if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = 1; ctx.stroke(); }
  return [bx, by, rx, ry];
}

// Roof with its ridge along x, over xa..xb, ya..yb, eaves at z, ridge at z + h.
function gable(ctx, c, xa, xb, ya, yb, z, h, base) {
  const ym = (ya + yb) / 2;
  poly(ctx, [P(xa, ya, z), P(xb, ya, z), P(xb, ym, z + h), P(xa, ym, z + h)], c(base, 0.8));
  poly(ctx, [P(xa, yb, z), P(xb, yb, z), P(xb, ym, z + h), P(xa, ym, z + h)], c(base, 1.12));
  poly(ctx, [P(xb, ya, z), P(xb, yb, z), P(xb, ym, z + h)], c(base, 0.66));
}

// A wheel standing in the plane y = cy (it faces the lower left of the screen).
function wheel(ctx, cx, cy, cz, r, rot, rim, spoke, n = 6, fill = null) {
  const pt = (a, rr = r) => P(cx + rr * Math.cos(a), cy, cz + rr * Math.sin(a));
  const ring = [];
  for (let i = 0; i < 20; i++) ring.push(pt((i / 20) * Math.PI * 2));
  poly(ctx, ring, fill, rim, 2);
  ctx.beginPath();
  for (let i = 0; i < n; i++) {
    const a = rot + (i / n) * Math.PI * 2;
    ctx.moveTo(...pt(a, r * 0.12)); ctx.lineTo(...pt(a, r * 0.92));
  }
  ctx.strokeStyle = spoke; ctx.lineWidth = 1.2; ctx.stroke();
}

function lamp(ctx, p, hex, a, r = 2.4) {
  glow(ctx, p[0], p[1], r * 4.5, hex, 0.55 * a);
  ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, Math.PI * 2);
  ctx.fillStyle = shade(hex, 0.55 + 0.7 * a); ctx.fill();
}

const windowsY = (ctx, c, on, y, x0, x1, z0, z1, n) => {
  const w = (x1 - x0) / n;
  for (let i = 0; i < n; i++) faceY(ctx, y, x0 + i * w + w * 0.18, x0 + (i + 1) * w - w * 0.18, z0, z1, on ? WIN_ON : c(WIN_OFF));
};
const windowsX = (ctx, c, on, x, y0, y1, z0, z1, n) => {
  const w = (y1 - y0) / n;
  for (let i = 0; i < n; i++) faceX(ctx, x, y0 + i * w + w * 0.18, y0 + (i + 1) * w - w * 0.18, z0, z1, on ? shade(WIN_ON, 0.8) : c(WIN_OFF));
};

// ---- styles ---------------------------------------------------------------

// The blog: a printing works. Paper runs between two drums on the front.
function press(ctx, b, s) {
  const { x, y } = b, c = s.col;
  cyl(ctx, c, x + 0.55, y + 0.5, 0.1, 0.18, 2.1, "#6f5144", { bands: [[1.75, 1.9, c("#e2e6ee")]], hollow: "#1a1a1a" });
  const xa = x + 0.25, xb = x + 2.75, ya = y + 0.75, yb = y + 2.1;
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 1.05, "#8a7f6c");
  windowsX(ctx, c, s.on, xb, ya, yb, 0.45, 0.8, 3);
  gable(ctx, c, xa, xb, ya, yb, 1.15, 0.5, "#5b4a3f");
  faceY(ctx, yb, xa, xb, 1.03, 1.15, c(s.accent));
  // the web of paper, from the left drum over a roller to the right drum
  const rot = s.on ? s.t * (1.2 + 5 * s.load) : 0.4;
  const y0 = y + 2.45;
  const paper = s.on ? "#f4f1e6" : c("#b9b6ad");
  ctx.beginPath();
  ctx.moveTo(...P(x + 0.75, y0, 1.02)); ctx.lineTo(...P(x + 1.5, y0, 1.25)); ctx.lineTo(...P(x + 2.25, y0, 1.02));
  ctx.strokeStyle = paper; ctx.lineWidth = 5; ctx.stroke();
  // print marks travelling along the web
  if (s.on) {
    ctx.beginPath();
    for (let i = 0; i < 4; i++) {
      const f = ((s.t * 0.5 + i / 4) % 1);
      const px = x + 0.75 + 1.5 * f, pz = 1.02 + 0.23 * (1 - Math.abs(f * 2 - 1));
      ctx.moveTo(...P(px, y0, pz)); ctx.lineTo(...P(px + 0.1, y0, pz));
    }
    ctx.strokeStyle = "#39404f"; ctx.lineWidth = 2.6; ctx.stroke();
  }
  box(ctx, c, x + 0.35, y + 2.3, 0.1, 0.8, 0.35, 0.3, "#4d5568");
  box(ctx, c, x + 1.85, y + 2.3, 0.1, 0.8, 0.35, 0.3, "#4d5568");
  wheel(ctx, x + 0.75, y + 2.66, 0.72, 0.36, rot, c("#c9a15a"), c("#e8d2a0"), 6, c("#2a3040"));
  wheel(ctx, x + 2.25, y + 2.66, 0.72, 0.36, -rot, c("#c9a15a"), c("#e8d2a0"), 6, c("#2a3040"));
  // a stack of finished sheets
  for (let i = 0; i < 3; i++) box(ctx, c, x + 1.3, y + 2.55, 0.1 + i * 0.09, 0.42, 0.3, 0.08, i % 2 ? "#e9e5d8" : "#f6f3ea");
}

// The old Phoenix app: a brick furnace with a tall stack.
function foundry(ctx, b, s) {
  const { x, y } = b, c = s.col;
  cyl(ctx, c, x + 0.6, y + 0.6, 0.1, 0.28, 2.8, "#8a4b38", {
    bands: [[2.3, 2.42, c("#d9d2c4")], [2.52, 2.64, c("#d9d2c4")]], hollow: "#1a1a1a",
  });
  box(ctx, c, x + 1.1, y + 0.4, 0.1, 1.6, 1.2, 0.9, "#7d5548");
  windowsX(ctx, c, s.on, x + 2.7, y + 0.4, y + 1.6, 0.4, 0.7, 2);
  // the kiln
  const heat = s.on ? 0.55 + 0.45 * Math.sin(s.t * 3) : 0;
  cyl(ctx, c, x + 1.35, y + 1.95, 0.1, 0.78, 1.15, "#9a5a44", {
    bands: [[0.0, 0.14, c("#3a3038")], [1.0, 1.15, c("#3a3038")]], top: c("#5a3a34"),
  });
  dome(ctx, x + 1.35, y + 1.95, 1.25, 0.78, 0.45, c("#6b4038"));
  // mouth on the front, glowing when it works
  const [mx, my] = P(x + 1.0, y + 2.6, 0.55);
  ctx.beginPath(); ctx.ellipse(mx, my, 9, 12, -0.45, 0, Math.PI * 2);
  ctx.fillStyle = s.on ? shade("#ff9a2e", 0.8 + 0.4 * heat) : c("#2a2226"); ctx.fill();
  ctx.strokeStyle = c("#2a2226"); ctx.lineWidth = 2; ctx.stroke();
  if (s.on) glow(ctx, mx, my, 34, "#ff7a1a", 0.3 + 0.3 * heat);
  // ladle and ingots
  box(ctx, c, x + 2.25, y + 2.2, 0.1, 0.5, 0.5, 0.35, "#4a4f5c");
  for (let i = 0; i < 3; i++) box(ctx, c, x + 2.3 + (i % 2) * 0.22, y + 2.8, 0.1 + Math.floor(i / 2) * 0.1, 0.2, 0.12, 0.1, s.on ? "#f2b84c" : "#8a7f6c");
}

// The link shortener: a signal box and a gantry of signals over the tracks.
function switchyard(ctx, b, s) {
  const { x, y } = b, c = s.col;
  // tracks painted on the pad
  ctx.beginPath();
  for (const dy of [1.55, 1.95]) { ctx.moveTo(...P(x + 0.1, y + dy, 0.11)); ctx.lineTo(...P(x + 2.9, y + dy, 0.11)); }
  ctx.moveTo(...P(x + 0.9, y + 1.95, 0.11)); ctx.lineTo(...P(x + 2.2, y + 2.75, 0.11));
  ctx.moveTo(...P(x + 0.9, y + 1.55, 0.11)); ctx.lineTo(...P(x + 2.2, y + 2.35, 0.11));
  ctx.strokeStyle = c("#aab2c2"); ctx.lineWidth = 1.2; ctx.stroke();
  // signal box on stilts
  box(ctx, c, x + 0.3, y + 0.3, 0.1, 1.3, 0.9, 0.55, "#5b6377");
  box(ctx, c, x + 0.2, y + 0.2, 0.65, 1.5, 1.1, 0.7, "#8f6a4a");
  windowsY(ctx, c, s.on, y + 1.3, x + 0.25, x + 1.65, 0.85, 1.2, 4);
  windowsX(ctx, c, s.on, x + 1.7, y + 0.25, y + 1.25, 0.85, 1.2, 2);
  gable(ctx, c, x + 0.15, x + 1.75, y + 0.15, y + 1.35, 1.35, 0.35, "#3f4658");
  // gantry across the tracks
  const gx0 = x + 2.3, gy0 = y + 1.25, gy1 = y + 2.9, gz = 2.0;
  line(ctx, P(gx0, gy0, 0.1), P(gx0, gy0, gz), c("#2f3542"), 2.4);
  line(ctx, P(gx0, gy1, 0.1), P(gx0, gy1, gz), c("#2f3542"), 2.4);
  line(ctx, P(gx0, gy0, gz), P(gx0, gy1, gz), c("#e0a526"), 3);
  line(ctx, P(gx0, gy0, gz - 0.25), P(gx0, gy1, gz - 0.25), c("#2f3542"), 1.2);
  ctx.beginPath();
  for (let i = 0; i < 4; i++) {
    const a = gy0 + (i * (gy1 - gy0)) / 4, e = gy0 + ((i + 1) * (gy1 - gy0)) / 4;
    ctx.moveTo(...P(gx0, a, gz)); ctx.lineTo(...P(gx0, e, gz - 0.25));
  }
  ctx.strokeStyle = c("#2f3542"); ctx.lineWidth = 0.9; ctx.stroke();
  // three signals: the one that is "through" changes as it works
  const live = s.on ? Math.floor(s.t * (0.4 + 2 * s.load)) % 3 : -1;
  for (let i = 0; i < 3; i++) {
    const p = P(gx0, gy0 + 0.3 + i * 0.52, gz - 0.5);
    line(ctx, P(gx0, gy0 + 0.3 + i * 0.52, gz - 0.25), p, c("#2f3542"), 1.6);
    lamp(ctx, p, i === live ? "#3ddc84" : "#ff5a5a", s.on ? (i === live ? 1 : 0.45) : 0.15, 2.6);
  }
}

// The gif maker: a sound stage with a reel on the roof and a clapper stripe.
function studio(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const xa = x + 0.3, xb = x + 2.7, ya = y + 0.4, yb = y + 2.5;
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 1.35, "#6d6a78");
  // clapper stripes along both eaves
  for (let i = 0; i < 8; i++) {
    const x0 = xa + (i * (xb - xa)) / 8, x1 = xa + ((i + 1) * (xb - xa)) / 8;
    faceY(ctx, yb, x0, x1, 1.2, 1.45, i % 2 ? c("#f1f1f1") : c("#20222a"));
  }
  for (let i = 0; i < 7; i++) {
    const y0 = ya + (i * (yb - ya)) / 7, y1 = ya + ((i + 1) * (yb - ya)) / 7;
    faceX(ctx, xb, y0, y1, 1.2, 1.45, i % 2 ? c("#bdbdbd") : c("#16181e"));
  }
  // big sliding door and a lit "recording" lamp
  faceY(ctx, yb, xa + 0.5, xa + 1.6, 0.1, 0.95, c("#3b4050"));
  line(ctx, P(xa + 1.05, yb, 0.1), P(xa + 1.05, yb, 0.95), c("#262a36"), 1);
  lamp(ctx, P(xa + 1.95, yb, 0.85), "#ff3b3b", s.on ? 0.6 + 0.4 * Math.sin(s.t * 4) : 0.12, 2.6);
  windowsX(ctx, c, s.on, xb, ya, yb, 0.45, 0.8, 3);
  // two reels on the roof, turning
  const rot = s.on ? s.t * (0.8 + 4 * s.load) : 0.3;
  line(ctx, P(x + 1.0, y + 1.7, 1.45), P(x + 1.0, y + 1.7, 1.75), c("#2b2f3a"), 2);
  line(ctx, P(x + 2.0, y + 1.7, 1.45), P(x + 2.0, y + 1.7, 1.75), c("#2b2f3a"), 2);
  wheel(ctx, x + 1.0, y + 1.7, 2.0, 0.45, rot, c("#d9dee8"), c("#8d95a6"), 5, c("#3a4152"));
  wheel(ctx, x + 2.0, y + 1.7, 1.9, 0.35, rot * 1.3, c("#d9dee8"), c("#8d95a6"), 5, c("#3a4152"));
  line(ctx, P(x + 1.0, y + 1.7, 2.45), P(x + 2.0, y + 1.7, 2.25), c("#1b1d24"), 1.4);
  // spotlight on the apron
  if (s.on) {
    const p = P(x + 0.5, y + 2.85, 0.45);
    ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(p[0] - 30, p[1] - 80); ctx.lineTo(p[0] + 6, p[1] - 86); ctx.closePath();
    ctx.fillStyle = alpha("#fff3c4", 0.1 + 0.05 * Math.sin(s.t * 2)); ctx.fill();
  }
  box(ctx, c, x + 0.38, y + 2.72, 0.1, 0.25, 0.25, 0.35, "#3d4354");
}

// Marginalia: a library. Columns, a pediment, book spines in the windows.
function library(ctx, b, s) {
  const { x, y } = b, c = s.col;
  box(ctx, c, x + 0.15, y + 0.3, 0.1, 2.7, 2.6, 0.18, "#b7b2a6");
  box(ctx, c, x + 0.3, y + 0.45, 0.28, 2.4, 2.3, 0.14, "#c4bfb2");
  const xa = x + 0.45, xb = x + 2.55, ya = y + 0.6, yb = y + 2.3;
  box(ctx, c, xa, ya, 0.42, xb - xa, yb - ya, 1.0, "#a59f92");
  // spines: narrow coloured windows on the side wall
  const spines = ["#c0504d", "#4f81bd", "#9bbb59", "#e0a526", "#8064a2", "#4bacc6", "#d98a3a"];
  for (let i = 0; i < 9; i++) {
    const y0 = ya + 0.12 + i * 0.175;
    faceX(ctx, xb, y0, y0 + 0.12, 0.6, 1.25, s.on ? spines[(i + s.seed) % spines.length] : c(spines[(i + s.seed) % spines.length], 0.45));
  }
  // portico
  const py = y + 2.62;
  for (let i = 0; i < 5; i++) cyl(ctx, c, xa + 0.2 + i * 0.425, py, 0.42, 0.075, 0.95, "#e6e1d5");
  faceY(ctx, yb, xa + 0.8, xa + 1.3, 0.42, 1.05, c("#3a3340"));
  box(ctx, c, xa, yb, 1.37, xb - xa, py - yb + 0.12, 0.1, "#d2ccbf");
  poly(ctx, [P(xa, py + 0.12, 1.47), P(xb, py + 0.12, 1.47), P((xa + xb) / 2, py + 0.12, 2.0)], c("#cbc5b8", 0.95));
  poly(ctx, [P(xb, yb, 1.47), P(xb, py + 0.12, 1.47), P((xa + xb) / 2, py + 0.12, 2.0), P((xa + xb) / 2, yb, 2.0)], c("#8f897c", 0.8));
  poly(ctx, [P(xa, ya, 1.42), P(xb, ya, 1.42), P(xb, yb, 1.42), P(xa, yb, 1.42)], c("#7d786c"));
  poly(ctx, [P(xa, yb, 1.47), P((xa + xb) / 2, yb, 2.0), P((xa + xb) / 2, py + 0.12, 2.0), P(xa, py + 0.12, 1.47)], c("#d9d3c6", 1.05));
  const [gx, gy] = P((xa + xb) / 2, py + 0.12, 1.66);
  ctx.beginPath(); ctx.arc(gx, gy, 3, 0, Math.PI * 2); ctx.fillStyle = c(s.accent); ctx.fill();
  if (s.on) glow(ctx, ...P(xa + 1.05, py, 0.7), 22, "#ffcf70", 0.3);
}

// Music: a hall with a rank of organ pipes behind it.
function conservatory(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const hs = [1.5, 1.9, 2.3, 2.7, 2.3, 1.9, 1.5];
  hs.forEach((h, i) => {
    const sound = s.on ? 0.5 + 0.5 * Math.sin(s.t * (2 + i * 0.7) + i) : 0;
    cyl(ctx, c, x + 0.45 + i * 0.35, y + 0.55, 0.1, 0.14, h, "#c9a23e", {
      bands: [[0.35, 0.45, c("#2a2f3b")]], hollow: "#1a1a1a", top: c("#e9cf7a"),
    });
    if (s.on) glow(ctx, ...P(x + 0.45 + i * 0.35, y + 0.55, h + 0.2), 9, "#ffe08a", 0.15 + 0.35 * sound);
  });
  const xa = x + 0.3, xb = x + 2.7, ya = y + 0.95, yb = y + 2.55;
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 0.95, "#7c5a4a");
  // arched windows
  for (let i = 0; i < 4; i++) {
    const x0 = xa + 0.2 + i * 0.57;
    faceY(ctx, yb, x0, x0 + 0.32, 0.3, 0.7, s.on ? WIN_ON : c(WIN_OFF));
    const [ax, ay] = P(x0 + 0.16, yb, 0.7);
    ctx.beginPath(); ctx.ellipse(ax, ay, 5.2, 5, -0.46, Math.PI, 0);
    ctx.fillStyle = s.on ? WIN_ON : c(WIN_OFF); ctx.fill();
  }
  windowsX(ctx, c, s.on, xb, ya, yb, 0.35, 0.7, 3);
  gable(ctx, c, xa - 0.08, xb + 0.08, ya - 0.08, yb + 0.08, 1.05, 0.55, "#4a3b45");
  faceY(ctx, yb + 0.08, xa - 0.08, xb + 0.08, 1.0, 1.07, c(s.accent));
  // notes drifting up when it plays
  if (s.on) {
    ctx.fillStyle = alpha("#ffe9a8", 0.85);
    ctx.font = "bold 11px system-ui, sans-serif"; ctx.textAlign = "center";
    for (let i = 0; i < 3; i++) {
      const age = (s.t * 0.3 + i / 3) % 1;
      const [nx, ny] = P(x + 1.5, y + 1.6, 1.7 + age * 1.3);
      ctx.globalAlpha = 1 - age;
      ctx.fillText(i % 2 ? "♪" : "♫", nx + Math.sin(age * 6 + i) * 8, ny);
    }
    ctx.globalAlpha = 1;
  }
}

// The Bluesky feeds: an observatory, slit open, telescope out.
function observatory(ctx, b, s) {
  const { x, y } = b, c = s.col;
  box(ctx, c, x + 1.75, y + 0.35, 0.1, 1.0, 1.0, 0.8, "#59627a");
  windowsX(ctx, c, s.on, x + 2.75, y + 0.35, y + 1.35, 0.35, 0.6, 2);
  const cx = x + 1.3, cy = y + 1.75, r = 1.02;
  cyl(ctx, c, cx, cy, 0.1, r, 0.85, "#aab3c4", { bands: [[0.7, 0.85, c(s.accent, 0.9)]], top: c("#8a93a6") });
  const [bx, by, rx] = dome(ctx, cx, cy, 0.95, r, 1.2, c("#dfe5ee"), c("#8d96a8"));
  // slit, turning slowly with the sky
  const a = s.on ? Math.sin(s.t * 0.25) * 0.5 : 0.2;
  const sx = bx + rx * 0.45 * Math.sin(a);
  ctx.beginPath();
  ctx.moveTo(sx - 6, by + 8); ctx.quadraticCurveTo(sx - 9, by - 28, sx - 2, by - 1.2 * ZH + 3);
  ctx.lineTo(sx + 5, by - 1.2 * ZH + 4); ctx.quadraticCurveTo(sx + 10, by - 26, sx + 8, by + 9);
  ctx.closePath(); ctx.fillStyle = "#12151d"; ctx.fill();
  // telescope
  const t0 = [sx + 1, by - 18], t1 = [sx + 22, by - 52];
  line(ctx, t0, t1, c("#3d4558"), 6);
  line(ctx, t0, t1, c("#8f9bb3"), 2.4);
  ctx.beginPath(); ctx.arc(t1[0], t1[1], 4, 0, Math.PI * 2); ctx.fillStyle = s.on ? "#9fe7ff" : c("#4b5263"); ctx.fill();
  if (s.on) glow(ctx, t1[0], t1[1], 14, "#9fe7ff", 0.35 + 0.25 * Math.sin(s.t * 3));
}

// This app: a control tower watching the floor.
function control(ctx, b, s) {
  const { x, y } = b, c = s.col;
  box(ctx, c, x + 0.3, y + 1.5, 0.1, 2.4, 1.2, 0.6, "#566078");
  windowsY(ctx, c, s.on, y + 2.7, x + 0.3, x + 2.7, 0.3, 0.5, 6);
  faceY(ctx, y + 2.7, x + 0.3, x + 2.7, 0.6, 0.7, c("#e8b730"));
  cyl(ctx, c, x + 1.1, y + 1.1, 0.1, 0.36, 2.2, "#8a93a6", { bands: [[0.9, 0.98, c("#e8b730")], [1.6, 1.68, c("#e8b730")]] });
  cyl(ctx, c, x + 1.1, y + 1.1, 2.3, 0.62, 0.12, "#5a6377");
  // glass cab
  cyl(ctx, c, x + 1.1, y + 1.1, 2.42, 0.56, 0.45, s.on ? "#7fd8f2" : "#4a5870", { top: c("#3f4759") });
  cyl(ctx, c, x + 1.1, y + 1.1, 2.87, 0.66, 0.08, "#3f4759");
  // radar bar
  const [rx, ry] = P(x + 1.1, y + 1.1, 3.2);
  line(ctx, P(x + 1.1, y + 1.1, 2.95), [rx, ry], c("#2b2f3a"), 1.6);
  const a = s.t * 1.6;
  ctx.beginPath(); ctx.ellipse(rx, ry, 17 * Math.abs(Math.cos(a)) + 1.5, 5, 0, 0, Math.PI * 2);
  ctx.fillStyle = c("#d9dee8"); ctx.fill();
  if (s.on) glow(ctx, rx, ry - 6, 10, "#ff5a5a", 0.3 + 0.3 * Math.sin(s.t * 4));
}

// The arena: a stadium bowl with floodlights.
function arena(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const cx = x + 1.5, cy = y + 1.5;
  const masts = [[0.3, 0.3], [2.7, 0.3], [2.7, 2.7], [0.3, 2.7]];
  const mast = ([mx, my]) => {
    const top = P(x + mx, y + my, 2.2);
    line(ctx, P(x + mx, y + my, 0.1), top, c("#2f3542"), 1.8);
    ctx.fillStyle = s.on ? "#fff6d0" : c("#5b6274");
    ctx.fillRect(top[0] - 6, top[1] - 4, 12, 6);
    if (s.on) glow(ctx, top[0], top[1], 24, "#fff1b8", 0.4);
  };
  masts.slice(0, 2).forEach(mast);
  cyl(ctx, c, cx, cy, 0.1, 1.28, 0.85, "#8791a6", {
    bands: [[0.0, 0.2, c("#4a5266")], [0.62, 0.74, c(s.accent)]], top: c("#a7b0c2"),
  });
  // stands sloping in, then the pitch
  const [px, py] = P(cx, cy, 0.95);
  const rx = 1.28 * TW * R2, ry = 1.28 * TH * R2;
  ctx.beginPath(); ctx.ellipse(px, py, rx * 0.86, ry * 0.86, 0, 0, Math.PI * 2); ctx.fillStyle = c("#5d667b"); ctx.fill();
  ctx.beginPath(); ctx.ellipse(px, py + 6, rx * 0.62, ry * 0.62, 0, 0, Math.PI * 2); ctx.fillStyle = s.on ? "#3f9b57" : c("#3c5a48"); ctx.fill();
  ctx.beginPath(); ctx.ellipse(px, py + 6, rx * 0.22, ry * 0.22, 0, 0, Math.PI * 2);
  ctx.moveTo(px - rx * 0.6, py + 6); ctx.lineTo(px + rx * 0.6, py + 6);
  ctx.strokeStyle = alpha("#ffffff", s.on ? 0.7 : 0.3); ctx.lineWidth = 1; ctx.stroke();
  // players: two dots chasing each other while it runs
  if (s.on) {
    for (let i = 0; i < 2; i++) {
      const a = s.t * 0.9 + i * Math.PI;
      ctx.beginPath(); ctx.arc(px + Math.cos(a) * rx * 0.4, py + 6 + Math.sin(a * 1.3) * ry * 0.35, 2.2, 0, Math.PI * 2);
      ctx.fillStyle = i ? "#ff5a5a" : "#4cc9f0"; ctx.fill();
    }
  }
  // gate
  const [gx, gy] = P(cx, cy + 1.28, 0.3);
  ctx.fillStyle = c("#20242e"); ctx.fillRect(gx - 7, gy - 12, 14, 16);
  masts.slice(2).forEach(mast);
}

// Deciduous: a glasshouse with a tree that has outgrown it.
function greenhouse(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const xa = x + 0.3, xb = x + 2.7, ya = y + 0.45, yb = y + 2.6;
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 0.22, "#6a5a4a");
  // back panes
  poly(ctx, [P(xa, ya, 0.3), P(xb, ya, 0.3), P(xb, ya, 1.2), P(xa, ya, 1.2)], alpha("#9fe7ff", 0.1));
  // tree
  const tx = x + 1.5, ty = y + 1.5;
  line(ctx, P(tx, ty, 0.3), P(tx, ty, 1.5), c("#6b4a2f"), 5);
  line(ctx, P(tx, ty, 1.0), P(tx - 0.5, ty, 1.6), c("#6b4a2f"), 2.5);
  line(ctx, P(tx, ty, 1.1), P(tx + 0.45, ty, 1.75), c("#6b4a2f"), 2.5);
  const leaf = ["#3f9b57", "#5fb45a", "#8bc34a", "#d9a441", "#c9662e"];
  const blobs = [[-0.6, 1.75, 15], [0.5, 1.9, 15], [0, 2.25, 19], [-0.25, 1.95, 14], [0.3, 2.35, 12], [-0.45, 2.3, 11]];
  blobs.forEach(([dx, dz, r], i) => {
    const sway = s.on ? Math.sin(s.t * 1.2 + i) * 1.5 : 0;
    const [px, py] = P(tx + dx, ty, dz);
    ctx.beginPath(); ctx.arc(px + sway, py, r, 0, Math.PI * 2);
    ctx.fillStyle = c(leaf[(i + s.seed) % leaf.length], 0.9 + (i % 3) * 0.1); ctx.fill();
  });
  // glass: front and side panes with frames, an open ridge
  const glass = s.on ? alpha("#b9f0ff", 0.26) : alpha("#9aa5b8", 0.2);
  poly(ctx, [P(xa, yb, 0.3), P(xb, yb, 0.3), P(xb, yb, 1.2), P(xa, yb, 1.2)], glass);
  poly(ctx, [P(xb, ya, 0.3), P(xb, yb, 0.3), P(xb, yb, 1.2), P(xb, ya, 1.2)], glass);
  const ym = (ya + yb) / 2;
  poly(ctx, [P(xa, yb, 1.2), P(xb, yb, 1.2), P(xb, ym + 0.35, 1.7), P(xa, ym + 0.35, 1.7)], glass);
  poly(ctx, [P(xb, ya, 1.2), P(xb, yb, 1.2), P(xb, ym + 0.35, 1.7), P(xb, ym - 0.35, 1.7)], glass);
  ctx.beginPath();
  for (let i = 0; i <= 4; i++) {
    const xx = xa + (i * (xb - xa)) / 4;
    ctx.moveTo(...P(xx, yb, 0.3)); ctx.lineTo(...P(xx, yb, 1.2)); ctx.lineTo(...P(xx, ym + 0.35, 1.7));
  }
  for (let i = 0; i <= 3; i++) {
    const yy = ya + (i * (yb - ya)) / 3;
    ctx.moveTo(...P(xb, yy, 0.3)); ctx.lineTo(...P(xb, yy, 1.2));
  }
  ctx.moveTo(...P(xa, yb, 1.2)); ctx.lineTo(...P(xb, yb, 1.2)); ctx.lineTo(...P(xb, ya, 1.2));
  ctx.moveTo(...P(xa, yb, 0.3)); ctx.lineTo(...P(xb, yb, 0.3)); ctx.lineTo(...P(xb, ya, 0.3));
  ctx.strokeStyle = c("#e6edf5"); ctx.lineWidth = 1; ctx.stroke();
  // a falling leaf
  if (s.on) {
    const age = (s.t * 0.2) % 1;
    const [lx, ly] = P(tx + 0.9, ty + 0.6, 2.2 - age * 2);
    ctx.fillStyle = alpha("#d9a441", 1 - age); ctx.fillRect(lx + Math.sin(age * 9) * 6, ly, 3, 2);
  }
}

// Games: a cabinet with a screen of falling blocks.
function arcade(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const xa = x + 0.4, xb = x + 2.6, ya = y + 0.5, yb = y + 2.3;
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 1.9, "#3a2f5c");
  // marquee
  faceY(ctx, yb, xa, xb, 1.6, 1.95, s.on ? shade(s.accent, 1.1) : c(s.accent, 0.5));
  faceX(ctx, xb, ya, yb, 1.6, 1.95, c(s.accent, 0.6));
  if (s.on) glow(ctx, ...P((xa + xb) / 2, yb, 1.78), 30, s.accent, 0.3);
  // screen: a 6 x 5 grid; blocks fall a row each beat
  const cols = 6, rows = 5, sx0 = xa + 0.2, sx1 = xb - 0.2, sz0 = 0.55, sz1 = 1.5;
  faceY(ctx, yb, sx0 - 0.05, sx1 + 0.05, sz0 - 0.05, sz1 + 0.05, "#0d0f16");
  const pal = ["#f94144", "#f9c74f", "#43aa8b", "#4cc9f0", "#b388ff"];
  const beat = s.on ? Math.floor(s.t * (1.5 + 4 * s.load)) : 0;
  for (let i = 0; i < cols; i++) {
    for (let j = 0; j < rows; j++) {
      const h = Math.imul((i + 1) * 73856093 ^ (j + beat) * 19349663 ^ s.seed, 2654435761) >>> 0;
      if (h % 5 > 1 + j * 0.6) continue;
      const cw = (sx1 - sx0) / cols, ch = (sz1 - sz0) / rows;
      faceY(ctx, yb, sx0 + i * cw + 0.02, sx0 + (i + 1) * cw - 0.02, sz1 - (j + 1) * ch + 0.02, sz1 - j * ch - 0.02,
        s.on ? pal[h % pal.length] : c(pal[h % pal.length], 0.35));
    }
  }
  // control deck with two buttons and a stick
  box(ctx, c, xa, yb, 0.1, xb - xa, 0.45, 0.42, "#4a3d73");
  lamp(ctx, P(xa + 0.7, yb + 0.25, 0.56), "#ff5a5a", s.on ? 0.9 : 0.2, 2.2);
  lamp(ctx, P(xa + 1.1, yb + 0.25, 0.56), "#4cc9f0", s.on ? 0.9 : 0.2, 2.2);
  line(ctx, P(xa + 1.7, yb + 0.22, 0.52), P(xa + 1.7 + (s.on ? Math.sin(s.t * 3) * 0.06 : 0), yb + 0.22, 0.82), c("#d9dee8"), 1.8);
  // neon strips up the side
  line(ctx, P(xb, ya + 0.15, 0.2), P(xb, ya + 0.15, 1.55), s.on ? "#f472b6" : c("#5a3550"), 1.6);
  line(ctx, P(xb, yb - 0.15, 0.2), P(xb, yb - 0.15, 1.55), s.on ? "#4cc9f0" : c("#2f4a5c"), 1.6);
}

// The decision-tree AI: a lab with a reactor sphere and a tree of lights.
function lab(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const xa = x + 0.3, xb = x + 1.9, ya = y + 0.4, yb = y + 2.6;
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, 1.25, "#dfe3ea");
  faceY(ctx, yb, xa, xb, 1.2, 1.35, c(s.accent));
  // a decision tree on the front wall: root, two branches, four leaves
  const node = (fx, fz) => P(xa + fx * (xb - xa), yb, fz);
  const tree = [[node(0.5, 1.05), node(0.27, 0.72)], [node(0.5, 1.05), node(0.73, 0.72)],
    [node(0.27, 0.72), node(0.14, 0.38)], [node(0.27, 0.72), node(0.4, 0.38)],
    [node(0.73, 0.72), node(0.6, 0.38)], [node(0.73, 0.72), node(0.86, 0.38)]];
  const pick = s.on ? Math.floor(s.t * (0.7 + 3 * s.load)) % 4 : -1;
  tree.forEach(([p, q], i) => {
    const lit = pick >= 0 && (i === (pick < 2 ? 0 : 1) || i === 2 + pick);
    line(ctx, p, q, lit ? "#3ddc84" : c("#7d8597"), lit ? 2.2 : 1.1);
  });
  for (const [, q] of tree) { ctx.beginPath(); ctx.arc(q[0], q[1], 2.2, 0, Math.PI * 2); ctx.fillStyle = c("#39404f"); ctx.fill(); }
  windowsX(ctx, c, s.on, xb, ya, yb, 0.45, 0.85, 3);
  // reactor sphere on a ring of legs
  const cx = x + 2.4, cy = y + 1.6;
  cyl(ctx, c, cx, cy, 0.1, 0.42, 0.35, "#5a6377");
  const [px, py] = P(cx, cy, 0.95);
  const g = ctx.createRadialGradient(px - 6, py - 7, 2, px, py, 22);
  g.addColorStop(0, s.on ? "#e9fbff" : c("#aab3c4")); g.addColorStop(1, s.on ? shade("#4cc9f0", 0.8) : c("#566078"));
  ctx.beginPath(); ctx.arc(px, py, 20, 0, Math.PI * 2); ctx.fillStyle = g; ctx.fill();
  ctx.beginPath(); ctx.ellipse(px, py, 20, 6, 0, 0, Math.PI * 2); ctx.strokeStyle = c("#39404f"); ctx.lineWidth = 1.4; ctx.stroke();
  if (s.on) glow(ctx, px, py, 40, "#4cc9f0", 0.2 + 0.15 * Math.sin(s.t * 3));
  // pipe from the sphere to the hall
  line(ctx, P(cx, cy, 1.5), P(xb, cy, 1.1), c("#b87333"), 2.4);
}

// Slides: a stage with a projector throwing onto a screen.
function stage(ctx, b, s) {
  const { x, y } = b, c = s.col;
  box(ctx, c, x + 0.3, y + 0.3, 0.1, 2.4, 0.4, 2.0, "#4a3140");
  // screen on the back wall, facing the audience
  const slide = s.on ? Math.floor(s.t * (0.25 + 1.5 * s.load)) : 0;
  const pal = ["#f4f1e6", "#dff3ff", "#fff0d0", "#e8ffe8"];
  faceY(ctx, y + 0.7, x + 0.6, x + 2.4, 0.75, 1.85, s.on ? pal[slide % pal.length] : c("#8d95a6"));
  // what is on the slide: a title bar and three bullets
  if (s.on) {
    faceY(ctx, y + 0.7, x + 0.75, x + 1.6 + (slide % 3) * 0.2, 1.55, 1.7, "#39404f");
    for (let i = 0; i < 3; i++) faceY(ctx, y + 0.7, x + 0.8, x + 1.4 + ((slide + i) % 4) * 0.22, 1.3 - i * 0.18, 1.37 - i * 0.18, "#7d8597");
  }
  // curtains
  faceY(ctx, y + 0.7, x + 0.3, x + 0.6, 0.6, 2.1, c("#9c2f3f"));
  faceY(ctx, y + 0.7, x + 2.4, x + 2.7, 0.6, 2.1, c("#9c2f3f"));
  faceY(ctx, y + 0.7, x + 0.3, x + 2.7, 1.9, 2.1, c("#b23a4c"));
  // stage floor and steps
  box(ctx, c, x + 0.3, y + 0.7, 0.1, 2.4, 1.2, 0.5, "#8a6a4a");
  box(ctx, c, x + 1.2, y + 1.9, 0.1, 0.6, 0.3, 0.25, "#7a5c40");
  // lectern
  box(ctx, c, x + 0.6, y + 1.3, 0.6, 0.3, 0.3, 0.5, "#5b4636");
  // projector on a stand, with its beam
  const pj = P(x + 1.5, y + 2.7, 0.85);
  line(ctx, P(x + 1.5, y + 2.7, 0.1), pj, c("#2f3542"), 2);
  if (s.on) {
    const a = P(x + 0.6, y + 0.72, 0.75), d = P(x + 2.4, y + 0.72, 1.85);
    ctx.beginPath(); ctx.moveTo(pj[0], pj[1] - 3); ctx.lineTo(a[0], a[1]); ctx.lineTo(d[0], d[1]); ctx.closePath();
    ctx.fillStyle = alpha("#fff6d6", 0.1); ctx.fill();
  }
  ctx.fillStyle = c("#3d4354"); ctx.fillRect(pj[0] - 7, pj[1] - 7, 14, 8);
  lamp(ctx, [pj[0] + 3, pj[1] - 4], "#fff1b8", s.on ? 0.9 : 0.1, 2);
}

export const STYLES = {
  press, foundry, switchyard, studio, library, conservatory, observatory, control, arena, greenhouse, arcade, lab, stage,
};

// Smoke leaves these points (world pixels).
export function styleChimneys(b) {
  const { x, y } = b;
  switch (b.node.style) {
    case "press": return [P(x + 0.55, y + 0.5, 2.25)];
    case "foundry": return [P(x + 0.6, y + 0.6, 2.95)];
    default: return [];
  }
}
