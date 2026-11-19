// Isometric projection and drawing primitives.
//
// World is in tiles: x runs down-right on screen, y down-left, z up.
// "World pixels" are the projection at zoom 1; the camera maps them to the
// canvas with one setTransform per frame.

export const TW = 32; // half tile width in px
export const TH = 16; // half tile height
export const ZH = 32; // px per unit of height
const R2 = Math.SQRT2;

export const P = (x, y, z = 0) => [(x - y) * TW, (x + y) * TH - z * ZH];

// ---- colour ---------------------------------------------------------------

const rgbCache = new Map();
function rgb(hex) {
  let v = rgbCache.get(hex);
  if (!v) {
    const h = hex.replace("#", "");
    v = [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
    rgbCache.set(hex, v);
  }
  return v;
}
const shadeCache = new Map();
// f: brightness multiplier. sat: 1 keeps colour, 0 is grey.
export function shade(hex, f = 1, sat = 1) {
  const key = `${hex}|${f}|${sat}`;
  let s = shadeCache.get(key);
  if (s) return s;
  let [r, g, b] = rgb(hex);
  if (sat !== 1) {
    const l = 0.3 * r + 0.59 * g + 0.11 * b;
    r = l + (r - l) * sat; g = l + (g - l) * sat; b = l + (b - l) * sat;
  }
  const c = (v) => Math.max(0, Math.min(255, Math.round(v * f)));
  s = `rgb(${c(r)},${c(g)},${c(b)})`;
  if (shadeCache.size > 4000) shadeCache.clear();
  shadeCache.set(key, s);
  return s;
}
export function alpha(hex, a) {
  const [r, g, b] = rgb(hex);
  return `rgba(${r},${g},${b},${a})`;
}

// A tone turns a base colour into what this building should show:
// normal, muted (status unknown: we do not know) or charred (down).
export function tone(kind) {
  if (kind === "muted") return (hex, f = 1) => shade(hex, f * 0.78, 0.12);
  if (kind === "charred") return (hex, f = 1) => shade(hex, f * 0.5, 0.45);
  return (hex, f = 1) => shade(hex, f);
}

// ---- primitives -----------------------------------------------------------

export function poly(ctx, pts, fill, stroke, lw = 1) {
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
  ctx.closePath();
  if (fill) { ctx.fillStyle = fill; ctx.fill(); }
  if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = lw; ctx.stroke(); }
}

// Axis-aligned box. col(hex, f) is a tone; faces are lit from the upper left.
export function box(ctx, col, x, y, z, w, d, h, base, opts = {}) {
  const top = opts.top ?? col(base, 1.12);
  const left = opts.left ?? col(base, 0.86);
  const right = opts.right ?? col(base, 0.64);
  if (h > 0) {
    poly(ctx, [P(x, y + d, z), P(x + w, y + d, z), P(x + w, y + d, z + h), P(x, y + d, z + h)], left);
    poly(ctx, [P(x + w, y, z), P(x + w, y + d, z), P(x + w, y + d, z + h), P(x + w, y, z + h)], right);
  }
  poly(ctx, [P(x, y, z + h), P(x + w, y, z + h), P(x + w, y + d, z + h), P(x, y + d, z + h)], top,
    opts.edge ? opts.edge : null, 0.6);
}

// Quad on the +y face (screen lower-left) of a box: from x0..x1 along x, z0..z1.
export function faceY(ctx, y, x0, x1, z0, z1, fill) {
  poly(ctx, [P(x0, y, z0), P(x1, y, z0), P(x1, y, z1), P(x0, y, z1)], fill);
}
// Quad on the +x face (screen lower-right): y0..y1 along y.
export function faceX(ctx, x, y0, y1, z0, z1, fill) {
  poly(ctx, [P(x, y0, z0), P(x, y1, z0), P(x, y1, z1), P(x, y0, z1)], fill);
}

// Vertical cylinder, axis at (cx, cy), radius r tiles, from z to z+h.
export function cyl(ctx, col, cx, cy, z, r, h, base, opts = {}) {
  const rx = r * TW * R2, ry = r * TH * R2;
  const [bx, by] = P(cx, cy, z);
  const ty = by - h * ZH;
  const g = ctx.createLinearGradient(bx - rx, 0, bx + rx, 0);
  g.addColorStop(0, col(base, 0.95));
  g.addColorStop(0.35, col(base, 1.08));
  g.addColorStop(1, col(base, 0.55));
  ctx.beginPath();
  ctx.moveTo(bx - rx, ty);
  ctx.lineTo(bx - rx, by);
  ctx.ellipse(bx, by, rx, ry, 0, Math.PI, 0, true);
  ctx.lineTo(bx + rx, ty);
  ctx.closePath();
  ctx.fillStyle = g;
  ctx.fill();
  if (opts.bands) {
    for (const [z0, z1, c] of opts.bands) {
      ctx.beginPath();
      ctx.ellipse(bx, by - z0 * ZH, rx, ry, 0, 0, Math.PI);
      ctx.lineTo(bx - rx, by - z1 * ZH);
      ctx.ellipse(bx, by - z1 * ZH, rx, ry, 0, Math.PI, 0, true);
      ctx.closePath();
      ctx.fillStyle = c;
      ctx.fill();
    }
  }
  ctx.beginPath();
  ctx.ellipse(bx, ty, rx, ry, 0, 0, Math.PI * 2);
  ctx.fillStyle = opts.top ?? col(base, 1.15);
  ctx.fill();
  if (opts.hollow) {
    ctx.beginPath();
    ctx.ellipse(bx, ty, rx * 0.78, ry * 0.78, 0, 0, Math.PI * 2);
    ctx.fillStyle = opts.hollow;
    ctx.fill();
  }
}

export function line(ctx, a, b, stroke, lw = 1) {
  ctx.beginPath();
  ctx.moveTo(a[0], a[1]);
  ctx.lineTo(b[0], b[1]);
  ctx.strokeStyle = stroke;
  ctx.lineWidth = lw;
  ctx.stroke();
}

export function glow(ctx, x, y, r, hex, a = 0.6) {
  const g = ctx.createRadialGradient(x, y, 0, x, y, r);
  g.addColorStop(0, alpha(hex, a));
  g.addColorStop(1, alpha(hex, 0));
  ctx.fillStyle = g;
  ctx.fillRect(x - r, y - r, r * 2, r * 2);
}

// Convex hull (monotone chain) for hit-testing building silhouettes.
export function hull(points) {
  const p = [...points].sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const cross = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const lo = [], up = [];
  for (const q of p) { while (lo.length >= 2 && cross(lo[lo.length - 2], lo[lo.length - 1], q) <= 0) lo.pop(); lo.push(q); }
  for (const q of p.reverse()) { while (up.length >= 2 && cross(up[up.length - 2], up[up.length - 1], q) <= 0) up.pop(); up.push(q); }
  return lo.slice(0, -1).concat(up.slice(0, -1));
}
export function inPoly(pt, poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i], [xj, yj] = poly[j];
    if ((yi > pt[1]) !== (yj > pt[1]) && pt[0] < ((xj - xi) * (pt[1] - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
