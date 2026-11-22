// Buildings of the Applications floor (apps.js), added to the page's styles
// under their own names so the renderer draws them like any other style:
//   otp-sup     a supervisor: a tower, as tall as node.height (memory)
//   otp-worker  a worker: a workshop with a sawtooth roof
//   otp-group   the engine's group of children past 25: a row of sheds and the count
//   otp-fold    what this page did not draw: a fenced yard and the count
// Same rules as styles.js: a 3 x 3 footprint at (b.x, b.y), s.col the tone,
// s.on while the process runs, s.t seconds. node.height is the top, in tiles.

import { P, box, faceX, faceY, poly, line, glow, shade } from "./iso.js";
import { STYLES, STYLE_HEIGHT } from "./styles.js";

const WIN_ON = "#ffcf70", WIN_OFF = "#2a3142";
const H = (s, b, d) => (typeof b.node.height === "number" ? b.node.height : d);

function sup(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const top = H(s, b, 2.6);
  const xa = x + 0.55, ya = y + 0.55, w = 1.9;
  // a plinth, the shaft, a crown in the accent colour
  box(ctx, c, x + 0.3, y + 0.3, 0.1, 2.4, 2.4, 0.3, "#5d6577");
  box(ctx, c, xa, ya, 0.4, w, w, top - 0.75, "#7f8aa3");
  const floors = Math.max(2, Math.floor((top - 0.9) / 0.38));
  for (let i = 0; i < floors; i++) {
    const z0 = 0.58 + i * 0.38, z1 = z0 + 0.2;
    const lit = s.on && (i + Math.floor(s.t * 0.7)) % 3 !== 0;
    for (let k = 0; k < 3; k++) {
      const u0 = xa + 0.15 + k * 0.58, u1 = u0 + 0.36;
      faceY(ctx, ya + w, u0, u1, z0, z1, lit ? WIN_ON : c(WIN_OFF));
      faceX(ctx, xa + w, ya + 0.15 + k * 0.58, ya + 0.51 + k * 0.58, z0, z1, lit ? shade(WIN_ON, 0.8) : c(WIN_OFF));
    }
  }
  box(ctx, c, xa - 0.08, ya - 0.08, top - 0.35, w + 0.16, w + 0.16, 0.2, s.accent);
  // the branching mark on the roof: one line down, three out
  const r = P(xa + w / 2, ya + w / 2, top - 0.15);
  line(ctx, r, P(xa + w / 2, ya + w / 2, top + 0.3), c("#c9d2e2"), 1.6);
  for (const [dx, dy] of [[-0.5, 0.35], [0.35, -0.5], [0.4, 0.4]]) line(ctx, P(xa + w / 2, ya + w / 2, top + 0.3), P(xa + w / 2 + dx, ya + w / 2 + dy, top + 0.12), c("#c9d2e2"), 1.2);
}

function worker(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const top = H(s, b, 1.4);
  const xa = x + 0.35, xb = x + 2.65, ya = y + 0.6, yb = y + 2.4;
  const wall = Math.max(0.5, top - 0.45);
  box(ctx, c, xa, ya, 0.1, xb - xa, yb - ya, wall, "#8c7f6a");
  // sawtooth roof: three teeth, glass on the steep side
  const n = 3, tw = (xb - xa) / n;
  for (let i = 0; i < n; i++) {
    const x0 = xa + i * tw, x1 = x0 + tw, z = 0.1 + wall;
    poly(ctx, [P(x0, ya, z), P(x0, yb, z), P(x1, yb, z + 0.35), P(x1, ya, z + 0.35)], c("#5b6272", 1.05));
    poly(ctx, [P(x1, ya, z), P(x1, yb, z), P(x1, yb, z + 0.35), P(x1, ya, z + 0.35)], s.on ? shade(WIN_ON, 0.9) : c("#3b4252"));
  }
  // a door and a window on the front
  faceY(ctx, yb, xa + 0.25, xa + 0.75, 0.1, Math.min(0.1 + wall, 0.75), c("#2f3442"));
  faceY(ctx, yb, xa + 1.1, xb - 0.25, 0.35, Math.min(0.1 + wall - 0.1, 0.75), s.on ? WIN_ON : c(WIN_OFF));
  if (s.on) {
    const [gx, gy] = P(xa + 1.5, yb, 0.55);
    glow(ctx, gx, gy, 18, "#ffcf70", 0.22 + 0.1 * Math.sin(s.t * 6));
  }
}

function group(ctx, b, s) {
  const { x, y } = b, c = s.col;
  const top = H(s, b, 1.6);
  const n = b.node.count ?? 0;
  const sheds = Math.max(2, Math.min(4, Math.ceil(Math.log2(Math.max(2, n)))));
  for (let i = 0; i < sheds; i++) {
    const sx = x + 0.3 + (i % 2) * 1.25, sy = y + 0.3 + Math.floor(i / 2) * 1.25;
    box(ctx, c, sx, sy, 0.1, 1.05, 1.05, top - 0.5 - (i % 3) * 0.12, i % 2 ? "#7a8296" : "#868ea3");
  }
  sign(ctx, b, s, `×${n}`, top);
}

function fold(ctx, b, s) {
  const { x, y } = b, c = s.col;
  // a fenced yard: what is there and not drawn
  box(ctx, c, x + 0.25, y + 0.25, 0.1, 2.5, 2.5, 0.08, "#5a606e");
  ctx.save(); ctx.setLineDash([3, 3]);
  poly(ctx, [P(x + 0.25, y + 0.25, 0.55), P(x + 2.75, y + 0.25, 0.55), P(x + 2.75, y + 2.75, 0.55), P(x + 0.25, y + 2.75, 0.55)], null, c("#c9ced8"), 1.2);
  ctx.restore();
  for (let i = 0; i < 4; i++) box(ctx, c, x + 0.6 + (i % 2) * 0.9, y + 0.6 + Math.floor(i / 2) * 0.9, 0.18, 0.6, 0.6, 0.35, "#4a505e");
  sign(ctx, b, s, `+${b.node.count ?? "?"}`, 1.5);
}

function sign(ctx, b, s, text, z) {
  const { x, y } = b, c = s.col;
  line(ctx, P(x + 1.5, y + 2.7, 0.1), P(x + 1.5, y + 2.7, z), c("#3b3f48"), 1.6);
  faceY(ctx, y + 2.7, x + 0.8, x + 2.2, z - 0.05, z + 0.5, c("#e8b730"));
  const [qx, qy] = P(x + 1.5, y + 2.7, z + 0.22);
  ctx.save();
  ctx.translate(qx, qy); ctx.transform(1, -0.5, 0, 1, 0, 0);
  ctx.fillStyle = "#1c1f26"; ctx.font = "bold 10px system-ui, sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
  ctx.fillText(text, 0, 0);
  ctx.restore();
}

Object.assign(STYLES, { "otp-sup": sup, "otp-worker": worker, "otp-group": group, "otp-fold": fold });
// defaults only: node.height wins (buildings.js heightOf)
Object.assign(STYLE_HEIGHT, { "otp-sup": 2.6, "otp-worker": 1.4, "otp-group": 1.6, "otp-fold": 1.5 });
