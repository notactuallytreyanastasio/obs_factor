// World layout: platforms, building footprints and belt routes, in tile units.
//
// A building slot (`pos` in the snapshot) is SLOT tiles square. The building
// stands on a FOOT x FOOT pad in the middle of it; the gap between pads is
// where belts run. Belts are routed with A* on a half-tile grid so two belts
// can share a gap side by side instead of on top of each other.

export const SLOT = 6;
export const FOOT = 3;
const MARGIN = 1; // tiles of platform floor around the slots
const GAP = 5; // tiles of space between platforms
const CELL = 0.5; // routing grid, tiles

export const UNPLACED = "__unplaced";

// Returns {platforms, nodes: Map(id -> placed), bounds, problems}.
// placed = {node, x, y, w, d} footprint in tiles; platform = {id,label,x,y,w,d,unplaced}
export function layout(snapshot, opts = {}) {
  const problems = [];
  const known = new Map(snapshot.platforms.map((p) => [p.id, p]));
  const groups = new Map();
  for (const p of snapshot.platforms) groups.set(p.id, []);
  const unplaced = [];
  const floating = [];
  const sources = [];

  for (const n of snapshot.nodes) {
    // The traffic source belongs to no platform: it gets a pad of its own.
    if (n.kind === "source" && n.platform == null) { sources.push(n); continue; }
    if (n.platform == null) { unplaced.push(n); continue; }
    // On a platform but with no slot (the host's CPU, memory and disk): the
    // next free slots of that platform, not the unplaced pad.
    if (n.pos == null && known.has(n.platform)) { floating.push(n); continue; }
    if (n.pos == null) { unplaced.push(n); continue; }
    if (!known.has(n.platform)) {
      problems.push(`node ${n.id} is on platform "${n.platform}", which is not in platforms`);
      unplaced.push(n);
      continue;
    }
    groups.get(n.platform).push(n);
  }

  // slot collisions: the second one goes to the unplaced pad, and we say so
  for (const [pid, list] of groups) {
    const seen = new Map();
    for (const n of [...list]) {
      const key = `${n.pos[0]},${n.pos[1]}`;
      if (seen.has(key)) {
        problems.push(`${n.id} and ${seen.get(key)} share slot ${key} on ${pid}`);
        list.splice(list.indexOf(n), 1);
        unplaced.push(n);
      } else seen.set(key, n.id);
    }
  }

  const plats = [];
  for (const p of snapshot.platforms) {
    const list = groups.get(p.id);
    const extra = floating.filter((n) => n.platform === p.id).sort((a, b) => a.id.localeCompare(b.id));
    if (list.length === 0 && extra.length === 0) continue;
    const members = list.map((n) => ({ n, c: n.pos[0], r: n.pos[1] }));
    let cols = Math.max(0, ...members.map((m) => m.c + 1));
    let rows = Math.max(0, ...members.map((m) => m.r + 1));
    if (extra.length) {
      // a row of their own below whatever the topology placed
      cols = Math.max(cols, extra.length);
      extra.forEach((n, i) => members.push({ n, c: i, r: rows }));
      rows += 1;
    }
    plats.push({ id: p.id, label: p.label, cols, rows, members });
  }
  if (sources.length) {
    plats.push({
      id: "__sources", label: "outside", cols: 1, rows: sources.length,
      members: sources.map((n, i) => ({ n, c: 0, r: i })),
    });
  }
  if (unplaced.length) {
    unplaced.sort((a, b) => a.id.localeCompare(b.id));
    const cols = Math.ceil(Math.sqrt(unplaced.length));
    plats.push({
      id: UNPLACED, label: "unplaced: not in the topology", unplaced: true,
      cols, rows: Math.ceil(unplaced.length / cols),
      members: unplaced.map((n, i) => ({ n, c: i % cols, r: Math.floor(i / cols) })),
    });
  }

  for (const p of plats) { p.w = p.cols * SLOT + 2 * MARGIN; p.d = p.rows * SLOT + 2 * MARGIN; }
  orderByBelts(plats, snapshot.edges);
  if (opts.tall) {
    // Portrait screens: a column of platforms down the screen, each centred
    // on screen x = 0. Screen x is (x - y), screen y is (x + y).
    let cursor = 0; // in (x + y) units
    for (const p of plats) {
      const diff = Math.round((p.d - p.w) / 2); // x - y that centres it
      const sum = cursor;
      p.x = Math.round((sum + diff) / 2); p.y = p.x - diff;
      cursor = p.x + p.y + p.w + p.d + GAP;
    }
  } else {
    // Shelf-pack along x, wrapping into rows along y.
    const area = plats.reduce((a, p) => a + (p.w + GAP) * (p.d + GAP), 0);
    const maxRow = Math.max(Math.sqrt(area) * 1.15, ...plats.map((p) => p.w));
    let x = 0, y = 0, rowD = 0;
    for (const p of plats) {
      if (x > 0 && x + p.w > maxRow) { x = 0; y += rowD + GAP; rowD = 0; }
      p.x = x; p.y = y;
      x += p.w + GAP;
      rowD = Math.max(rowD, p.d);
    }
  }

  const nodes = new Map();
  for (const p of plats) {
    for (const { n, c, r } of p.members) {
      nodes.set(n.id, {
        node: n, platform: p,
        x: p.x + MARGIN + c * SLOT + (SLOT - FOOT) / 2,
        y: p.y + MARGIN + r * SLOT + (SLOT - FOOT) / 2,
        w: FOOT, d: FOOT,
      });
    }
  }

  const bounds = {
    x0: Math.min(...plats.map((p) => p.x)), y0: Math.min(...plats.map((p) => p.y)),
    x1: Math.max(...plats.map((p) => p.x + p.w)), y1: Math.max(...plats.map((p) => p.y + p.d)),
  };
  return { platforms: plats, nodes, bounds, problems };
}

// Put platforms that share many belts next to each other, so a bundle of
// belts does not cross a third platform. Starts from the platform holding
// the traffic source; the unplaced pad stays last.
function orderByBelts(plats, edges) {
  const where = new Map();
  for (const p of plats) for (const { n } of p.members) where.set(n.id, p);
  const weight = (a, b) => edges.reduce((s, e) => {
    const pa = where.get(e.from), pb = where.get(e.to);
    return s + ((pa === a && pb === b) || (pa === b && pb === a) ? 1 : 0);
  }, 0);
  const rest = plats.filter((p) => !p.unplaced);
  const tail = plats.filter((p) => p.unplaced);
  if (rest.length < 3) return;
  const srcPlat = rest.find((p) => p.members.some(({ n }) => n.kind === "source")) ?? rest[0];
  const out = [srcPlat];
  rest.splice(rest.indexOf(srcPlat), 1);
  while (rest.length) {
    const last = out[out.length - 1];
    let best = rest[0], bw = -1;
    for (const p of rest) {
      // prefer belts to the last placed platform, then to any placed one
      const w = weight(last, p) * 100 + out.reduce((s, q) => s + weight(q, p), 0);
      if (w > bw) { bw = w; best = p; }
    }
    out.push(best);
    rest.splice(rest.indexOf(best), 1);
  }
  plats.splice(0, plats.length, ...out, ...tail);
}

// ---- belt routing ---------------------------------------------------------

class Heap {
  constructor() { this.a = []; }
  push(item, pri) {
    const a = this.a; a.push([pri, item]);
    let i = a.length - 1;
    while (i > 0) { const p = (i - 1) >> 1; if (a[p][0] <= a[i][0]) break; [a[p], a[i]] = [a[i], a[p]]; i = p; }
  }
  pop() {
    const a = this.a; const top = a[0]; const last = a.pop();
    if (a.length) {
      a[0] = last; let i = 0;
      for (;;) {
        const l = 2 * i + 1, r = l + 1; let m = i;
        if (l < a.length && a[l][0] < a[m][0]) m = l;
        if (r < a.length && a[r][0] < a[m][0]) m = r;
        if (m === i) break; [a[m], a[i]] = [a[i], a[m]]; i = m;
      }
    }
    return top[1];
  }
  get size() { return this.a.length; }
}

const DIRS = [[1, 0], [0, 1], [-1, 0], [0, -1]];

// Returns Map(edgeId -> {edge, pts: [[x,y],...] in tiles, len, bridge: bool})
// and a list of problems (edges naming nodes that are not there).
export function routeBelts(world, edges) {
  const problems = [];
  const b = world.bounds;
  const ox = b.x0 - 2, oy = b.y0 - 2;
  const W = Math.ceil((b.x1 - b.x0 + 4) / CELL), H = Math.ceil((b.y1 - b.y0 + 4) / CELL);
  // 0 floor, 1 void, 2 building
  const grid = new Uint8Array(W * H).fill(1);
  const owner = new Int16Array(W * H).fill(-1);
  const used = new Uint8Array(W * H);
  const toCell = (v, o) => Math.floor((v - o) / CELL);

  for (const p of world.platforms) {
    for (let cy = toCell(p.y, oy); cy < toCell(p.y + p.d, oy); cy++)
      for (let cx = toCell(p.x, ox); cx < toCell(p.x + p.w, ox); cx++) grid[cy * W + cx] = 0;
  }
  const ids = [...world.nodes.keys()];
  ids.forEach((id, i) => {
    const n = world.nodes.get(id);
    for (let cy = toCell(n.y, oy); cy < toCell(n.y + n.d, oy); cy++)
      for (let cx = toCell(n.x, ox); cx < toCell(n.x + n.w, ox); cx++) { grid[cy * W + cx] = 2; owner[cy * W + cx] = i; }
  });

  // Cells touching a footprint, with the inward direction.
  const ring = (n) => {
    const out = [];
    const x0 = toCell(n.x, ox), y0 = toCell(n.y, oy);
    const x1 = toCell(n.x + n.w, ox) - 1, y1 = toCell(n.y + n.d, oy) - 1;
    for (let cx = x0 + 1; cx < x1; cx++) { out.push([cx, y0 - 1, 0, 1]); out.push([cx, y1 + 1, 0, -1]); }
    for (let cy = y0 + 1; cy < y1; cy++) { out.push([x0 - 1, cy, 1, 0]); out.push([x1 + 1, cy, -1, 0]); }
    return out.filter(([cx, cy]) => cx >= 0 && cy >= 0 && cx < W && cy < H && grid[cy * W + cx] !== 2);
  };

  // Long belts first get the straightest lanes; short ones fit around them.
  const order = edges
    .map((e) => {
      const a = world.nodes.get(e.from), c = world.nodes.get(e.to);
      if (!a || !c) { problems.push(`edge ${e.id} names ${!a ? e.from : e.to}, which is not a node`); return null; }
      return { e, a, c, dist: Math.abs(a.x - c.x) + Math.abs(a.y - c.y) };
    })
    .filter(Boolean)
    .sort((p, q) => q.dist - p.dist);

  const routes = new Map();
  for (const { e, a, c } of order) {
    const starts = ring(a), goals = ring(c);
    const goalSet = new Map(goals.map(([cx, cy, dx, dy]) => [cy * W + cx, [dx, dy]]));
    const gx = (c.x + c.w / 2 - ox) / CELL, gy = (c.y + c.d / 2 - oy) / CELL;
    const N = W * H * 4;
    const cost = new Float32Array(N).fill(Infinity);
    const prev = new Int32Array(N).fill(-1);
    const heap = new Heap();
    for (const [cx, cy, dx, dy] of starts) {
      const d = DIRS.findIndex(([x, y]) => x === -dx && y === -dy);
      const s = (cy * W + cx) * 4 + d;
      cost[s] = used[cy * W + cx] ? 6 : 0;
      heap.push(s, cost[s] + Math.abs(cx - gx) + Math.abs(cy - gy));
    }
    let found = -1;
    while (heap.size) {
      const s = heap.pop();
      const ci = s >> 2, d = s & 3;
      const cx = ci % W, cy = (ci / W) | 0;
      if (goalSet.has(ci)) { found = s; break; }
      for (let nd = 0; nd < 4; nd++) {
        if (nd === ((d + 2) & 3)) continue;
        const nx = cx + DIRS[nd][0], ny = cy + DIRS[nd][1];
        if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
        const ni = ny * W + nx;
        if (grid[ni] === 2) continue;
        let step = grid[ni] === 1 ? 2.5 : 1;
        if (nd !== d) step += 3;
        if (used[ni]) step += used[ni] > 1 ? 14 : 8;
        const ns = ni * 4 + nd;
        const nc = cost[s] + step;
        if (nc < cost[ns]) {
          cost[ns] = nc; prev[ns] = s;
          heap.push(ns, nc + Math.abs(nx - gx) + Math.abs(ny - gy));
        }
      }
    }
    if (found < 0) { problems.push(`no route for belt ${e.id}`); continue; }
    const cells = [];
    for (let s = found; s >= 0; s = prev[s]) cells.push(s >> 2);
    cells.reverse();
    let bridge = false;
    for (const ci of cells) { used[ci] = Math.min(255, used[ci] + 1); if (grid[ci] === 1) bridge = true; }

    const center = (ci) => [ox + ((ci % W) + 0.5) * CELL, oy + (((ci / W) | 0) + 0.5) * CELL];
    // stubs: from the source wall to the first cell, from the last cell into the target wall
    const first = center(cells[0]), last = center(cells[cells.length - 1]);
    const wallPoint = (n, p) => [
      Math.min(Math.max(p[0], n.x), n.x + n.w), Math.min(Math.max(p[1], n.y), n.y + n.d),
    ];
    const raw = [wallPoint(a, first), ...cells.map(center), wallPoint(c, last)];
    const pts = simplify(raw);
    let len = 0;
    for (let i = 1; i < pts.length; i++) len += Math.abs(pts[i][0] - pts[i - 1][0]) + Math.abs(pts[i][1] - pts[i - 1][1]);
    routes.set(e.id, { edge: e, pts, len, bridge });
  }
  return { routes, problems };
}

function simplify(pts) {
  const out = [pts[0]];
  for (let i = 1; i < pts.length - 1; i++) {
    const a = out[out.length - 1], b = pts[i], c = pts[i + 1];
    const col = (a[0] === b[0] && b[0] === c[0]) || (a[1] === b[1] && b[1] === c[1]);
    if (!col) out.push(b);
  }
  out.push(pts[pts.length - 1]);
  return out;
}

// Topology fingerprint: re-layout only when this changes, not every tick.
export function topoKey(s) {
  return JSON.stringify([
    s.platforms.map((p) => p.id),
    s.nodes.map((n) => [n.id, n.kind, n.style ?? null, n.platform, n.pos]),
    s.edges.map((e) => [e.id, e.from, e.to]),
  ]);
}
