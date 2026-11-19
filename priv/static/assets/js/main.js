// obs_factor: the box drawn as a factory. Boot, input, render loop.

import { Scene, clampZoom } from "./render.js";
import { P } from "./iso.js";
import { Chips, TopBar, renderAttention, renderLegend, renderSites } from "./overlay.js";
import { Inspector } from "./inspector.js";
import { connect } from "./live.js";
import { canEnter, interiorSnapshot } from "./inside.js";

const $ = (id) => document.getElementById(id);
const canvas = $("floor");
const scene = new Scene(canvas);
const chips = new Chips($("labels"));
const topbar = new TopBar();
const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
scene.motion = !reduced.matches;
reduced.addEventListener?.("change", () => { scene.motion = !reduced.matches; dirty = true; });

let snap = null; // what is on screen: the floor, or the inside of one building
let outerSnap = null; // always the floor as the observer sent it
let insideOf = null; // id of the building we are inside, or null
let inspectOuter = false; // the inspector is showing the building itself while we are inside it
let dirty = true;
let fitted = false;
let fly = null;

const inspector = new Inspector({
  onClose: () => { scene.selected = null; dirty = true; },
  onNavigate: (id) => {
    if (insideOf && (inspectOuter || !snap.nodes.some((n) => n.id === id))) { leave(); select(id, true); } else select(id, true);
  },
});

// ---- viewport -------------------------------------------------------------

function freeArea() {
  const w = window.innerWidth, h = window.innerHeight;
  const top = $("topbar").offsetHeight + ($("attention").hidden ? 0 : $("attention").offsetHeight) + ($("insidebar").hidden ? 0 : $("insidebar").offsetHeight);
  let x = 0, y = top, fw = w, fh = h - top;
  if (inspector.open) {
    const r = inspector.el.getBoundingClientRect();
    if (w >= 760) fw = r.left - x;
    else fh = r.top - y;
  }
  return { x, y, w: Math.max(80, fw), h: Math.max(80, fh) };
}

function resize() {
  scene.resize(window.innerWidth, window.innerHeight);
  if (scene.setTall(window.innerWidth / window.innerHeight < 0.85)) {
    chips.update(snap);
    renderAttention(snap, scene.problems, (id) => select(id, true), () => toggleLegend(true));
    fitAll();
  }
  drawStars();
  dirty = true;
}
window.addEventListener("resize", resize);

function drawStars() {
  const c = $("stars");
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const w = window.innerWidth, h = window.innerHeight;
  c.width = w * dpr; c.height = h * dpr; c.style.width = `${w}px`; c.style.height = `${h}px`;
  const ctx = c.getContext("2d");
  ctx.scale(dpr, dpr);
  // A ringed planet low on the horizon, behind everything.
  {
    const R = Math.max(w, h) * 0.34, px = w * 0.86, py = h + R * 0.52;
    const g = ctx.createRadialGradient(px - R * 0.35, py - R * 0.55, R * 0.1, px, py, R);
    g.addColorStop(0, "#5b4f86"); g.addColorStop(0.55, "#2b2a55"); g.addColorStop(1, "#11132a");
    ctx.fillStyle = g; ctx.beginPath(); ctx.arc(px, py, R, 0, Math.PI * 2); ctx.fill();
    ctx.save(); ctx.translate(px, py); ctx.rotate(-0.32);
    for (let i = 0; i < 9; i++) {
      ctx.beginPath(); ctx.ellipse(0, 0, R * (1.25 + i * 0.055), R * (0.2 + i * 0.012), 0, Math.PI * 1.02, Math.PI * 1.98);
      ctx.strokeStyle = `rgba(${200 - i * 6},${190 - i * 4},${230},${0.05 + (i % 3) * 0.035})`;
      ctx.lineWidth = R * 0.03; ctx.stroke();
    }
    ctx.restore();
  }
  let seed = 1234567;
  const r = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const n = Math.round((w * h) / 2600);
  for (let i = 0; i < n; i++) {
    const x = r() * w, y = r() * h, s = r();
    ctx.fillStyle = `rgba(220,230,255,${0.25 + s * 0.6})`;
    const size = s > 0.97 ? 2.2 : s > 0.8 ? 1.4 : 0.9;
    ctx.fillRect(x, y, size, size);
    if (s > 0.985) {
      const g = ctx.createRadialGradient(x, y, 0, x, y, 7);
      g.addColorStop(0, "rgba(220,230,255,0.5)"); g.addColorStop(1, "rgba(220,230,255,0)");
      ctx.fillStyle = g; ctx.fillRect(x - 7, y - 7, 14, 14);
    }
  }
}

// ---- camera ---------------------------------------------------------------

// Fit everything; if that makes buildings illegibly small (a phone), start
// at a legible zoom over the busiest platform instead and let the user pan.
const MIN_START_ZOOM = 0.42;
function fitAll(animate = false, start = false) {
  if (!scene.world) return;
  const from = { ...scene.cam };
  scene.fit(freeArea());
  if (start && scene.cam.z < MIN_START_ZOOM) {
    const big = [...scene.world.platforms].sort((a, b) => b.members.length - a.members.length)[0];
    const f = freeArea();
    const z = MIN_START_ZOOM;
    const c = P(big.x + big.w / 2, big.y + big.d / 2);
    scene.cam.z = z;
    scene.cam.x = c[0] - (f.x + f.w / 2 - scene.view.w / 2) / z;
    scene.cam.y = c[1] - (f.y + f.h / 2 - scene.view.h / 2) / z;
  }
  if (animate && scene.motion) { const to = { ...scene.cam }; Object.assign(scene.cam, from); startFly(to); }
  dirty = true;
}

function centreOn(id, zoom) {
  const c = scene.nodeCenter(id);
  if (!c) return;
  const f = freeArea();
  const z = clampZoom(zoom ?? Math.max(scene.cam.z, 0.85));
  const sx = f.x + f.w / 2, sy = f.y + f.h * 0.55;
  const to = { z, x: c[0] - (sx - scene.view.w / 2) / z, y: c[1] - (sy - scene.view.h / 2) / z };
  if (scene.motion) startFly(to); else { Object.assign(scene.cam, to); dirty = true; }
}

function startFly(to, dur = 650, then = null) {
  fly = { from: { ...scene.cam }, to, t0: performance.now(), dur, then };
}

function stepFly(now) {
  if (!fly) return;
  const k = Math.min(1, (now - fly.t0) / fly.dur);
  const e = k < 0.5 ? 4 * k * k * k : 1 - (-2 * k + 2) ** 3 / 2;
  // zoom geometrically so the fly feels even
  scene.cam.z = fly.from.z * (fly.to.z / fly.from.z) ** e;
  scene.cam.x = fly.from.x + (fly.to.x - fly.from.x) * e;
  scene.cam.y = fly.from.y + (fly.to.y - fly.from.y) * e;
  dirty = true;
  if (k >= 1) { const then = fly.then; fly = null; if (then) then(); }
}

function zoomAt(sx, sy, factor) {
  const before = scene.toWorld([sx, sy]);
  scene.cam.z = clampZoom(scene.cam.z * factor);
  const after = scene.toWorld([sx, sy]);
  scene.cam.x += before[0] - after[0];
  scene.cam.y += before[1] - after[1];
  fly = null;
  dirty = true;
}

// ---- inside a building ------------------------------------------------------
// A building that reports its own inside opens into a floor of its own: the
// camera dives into it, the floor is swapped for the inside, and the view
// pulls back out to show all of it. Leaving does the reverse.

function showView() {
  const node = insideOf && outerSnap.nodes.find((n) => n.id === insideOf);
  if (insideOf && !canEnter(node)) {
    // the building is gone or stopped reporting: back to the floor, and say why
    const why = !node ? "it is no longer in the snapshot" : `its report is failing: ${node.inside?.error ?? "no report"}`;
    insideOf = null; inspectOuter = false;
    $("insidebar").hidden = true; document.body.classList.remove("inside");
    scene.theme = null;
    console.error(`obs_factor: left the inside view, ${why}`);
  }
  snap = insideOf ? interiorSnapshot(outerSnap, node) : outerSnap;
  const changed = scene.setSnapshot(snap);
  chips.update(snap);
  topbar.snapshot(outerSnap);
  renderAttention(outerSnap, scene.problems, (id) => { if (insideOf) leave(); select(id, true); }, () => toggleLegend(true));
  renderLegend(snap);
  renderSites(outerSnap, (id) => { if (window.innerWidth < 700) toggleSites(false); if (insideOf) leave(); select(id, true); });
  if (insideOf) {
    const i = snap.interior;
    $("inside-name").textContent = i.label;
    $("inside-kind").textContent = [i.kind, ...Object.entries(i.versions).map(([k, v]) => `${k} ${v}`)].join(" · ");
  }
  if (inspector.open) inspector.update(inspectOuter ? outerSnap : snap);
  dirty = true;
  return changed;
}

function enter(id) {
  if (insideOf || !outerSnap) return;
  const c = scene.nodeCenter(id);
  if (!c) return;
  inspector.close();
  const swap = () => {
    insideOf = id; inspectOuter = false;
    scene.selected = null; scene.hover = null;
    scene.theme = "inside";
    document.body.classList.add("inside");
    $("insidebar").hidden = false;
    showView();
    scene.fit(freeArea());
    if (scene.motion) { const to = { ...scene.cam }; scene.cam.z = clampZoom(to.z * 0.3); startFly(to, 520); }
    dirty = true;
  };
  if (!scene.motion) return swap();
  const f = freeArea();
  const z = 2.6;
  startFly({ z, x: c[0] - (f.x + f.w / 2 - scene.view.w / 2) / z, y: c[1] - (f.y + f.h / 2 - scene.view.h / 2) / z }, 420, swap);
}

function leave() {
  if (!insideOf) return;
  const id = insideOf;
  insideOf = null; inspectOuter = false;
  inspector.close();
  scene.selected = null; scene.hover = null;
  scene.theme = null;
  document.body.classList.remove("inside");
  $("insidebar").hidden = true;
  showView();
  scene.fit(freeArea());
  const c = scene.nodeCenter(id);
  if (scene.motion && c) {
    const to = { ...scene.cam };
    const f = freeArea();
    const z = 2.2;
    Object.assign(scene.cam, { z, x: c[0] - (f.x + f.w / 2 - scene.view.w / 2) / z, y: c[1] - (f.y + f.h / 2 - scene.view.h / 2) / z });
    startFly(to, 600);
    scene.flash = { id, until: performance.now() + 1600 };
  }
  dirty = true;
}

// A click on the floor: a building with an inside opens; anything else is inspected.
function activate(id) {
  const node = snap.nodes.find((n) => n.id === id);
  if (!insideOf && canEnter(node)) enter(id);
  else select(id);
}

function select(id, flyTo = false) {
  if (!snap) return;
  scene.selected = id;
  inspectOuter = false;
  inspector.show(id, snap, { history: !insideOf });
  if (flyTo) { centreOn(id); scene.flash = { id, until: performance.now() + 1600 }; }
  else {
    // keep the picked building in view beside the panel / above the sheet
    const c = scene.nodeCenter(id);
    const f = freeArea();
    const [sx, sy] = scene.toScreen(c);
    if (sx < f.x + 40 || sx > f.x + f.w - 40 || sy < f.y + 40 || sy > f.y + f.h - 20) centreOn(id, scene.cam.z);
  }
  dirty = true;
}

// ---- input ----------------------------------------------------------------

const pointers = new Map();
let gesture = null;

canvas.addEventListener("pointerdown", (e) => {
  canvas.setPointerCapture(e.pointerId);
  pointers.set(e.pointerId, [e.clientX, e.clientY]);
  fly = null;
  if (pointers.size === 1) gesture = { kind: "pan", start: [e.clientX, e.clientY], last: [e.clientX, e.clientY], t0: performance.now(), moved: 0 };
  else if (pointers.size === 2) {
    const [a, b] = [...pointers.values()];
    gesture = { kind: "pinch", dist: Math.hypot(a[0] - b[0], a[1] - b[1]), mid: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], moved: 99 };
  }
});

canvas.addEventListener("pointermove", (e) => {
  if (!pointers.has(e.pointerId)) {
    if (e.pointerType === "mouse" && snap) {
      const id = scene.hit(e.clientX, e.clientY);
      if (id !== scene.hover) { scene.hover = id; dirty = true; canvas.classList.toggle("pointing", !!id); }
    }
    return;
  }
  pointers.set(e.pointerId, [e.clientX, e.clientY]);
  if (!gesture) return;
  if (gesture.kind === "pan" && pointers.size === 1) {
    const dx = e.clientX - gesture.last[0], dy = e.clientY - gesture.last[1];
    gesture.last = [e.clientX, e.clientY];
    gesture.moved = Math.max(gesture.moved, Math.hypot(e.clientX - gesture.start[0], e.clientY - gesture.start[1]));
    if (gesture.moved > 5) canvas.classList.add("dragging");
    scene.cam.x -= dx / scene.cam.z;
    scene.cam.y -= dy / scene.cam.z;
    dirty = true;
  } else if (gesture.kind === "pinch" && pointers.size === 2) {
    const [a, b] = [...pointers.values()];
    const dist = Math.hypot(a[0] - b[0], a[1] - b[1]);
    const mid = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
    zoomAt(mid[0], mid[1], dist / gesture.dist);
    scene.cam.x -= (mid[0] - gesture.mid[0]) / scene.cam.z;
    scene.cam.y -= (mid[1] - gesture.mid[1]) / scene.cam.z;
    gesture.dist = dist; gesture.mid = mid;
  }
});

function endPointer(e) {
  if (!pointers.has(e.pointerId)) return;
  pointers.delete(e.pointerId);
  canvas.classList.remove("dragging");
  if (gesture?.kind === "pan" && pointers.size === 0 && gesture.moved < 6 && e.type === "pointerup") {
    const id = scene.hit(e.clientX, e.clientY);
    if (id) activate(id);
    else if (inspector.open) inspector.close();
  }
  if (pointers.size === 1) {
    const [p] = [...pointers.values()];
    gesture = { kind: "pan", start: p, last: p, t0: performance.now(), moved: 99 };
  } else if (pointers.size === 0) gesture = null;
}
canvas.addEventListener("pointerup", endPointer);
canvas.addEventListener("pointercancel", endPointer);
canvas.addEventListener("wheel", (e) => {
  e.preventDefault();
  const k = e.ctrlKey ? 0.01 : 0.0018; // trackpad pinch arrives as ctrl+wheel
  zoomAt(e.clientX, e.clientY, Math.exp(-e.deltaY * k));
}, { passive: false });

$("zoomin").addEventListener("click", () => { const f = freeArea(); zoomAt(f.x + f.w / 2, f.y + f.h / 2, 1.35); });
$("zoomout").addEventListener("click", () => { const f = freeArea(); zoomAt(f.x + f.w / 2, f.y + f.h / 2, 1 / 1.35); });
$("fitbtn").addEventListener("click", () => fitAll(true));
$("fitbtn2").addEventListener("click", () => { toggleMenu(false); fitAll(true); });

function toggleLegend(open) {
  const lg = $("legend");
  lg.hidden = !(open ?? lg.hidden);
  $("legendbtn").setAttribute("aria-expanded", String(!lg.hidden));
  if (!lg.hidden) toggleSites(false);
}
$("legendbtn").addEventListener("click", () => toggleLegend());
function toggleSites(open) {
  const el = $("sites");
  el.hidden = !(open ?? el.hidden);
  $("sitesbtn").setAttribute("aria-expanded", String(!el.hidden));
  if (!el.hidden) toggleLegend(false);
}
$("sitesbtn").addEventListener("click", () => toggleSites());
function toggleMenu(open) {
  const m = $("menu");
  m.hidden = !(open ?? m.hidden);
  $("menubtn").setAttribute("aria-expanded", String(!m.hidden));
}
$("menubtn").addEventListener("click", () => toggleMenu());
document.addEventListener("pointerdown", (e) => {
  if (!$("menu").hidden && !e.target.closest("#menu, #menubtn")) toggleMenu(false);
});

// ---- data -----------------------------------------------------------------

function onSnapshot(s) {
  outerSnap = s;
  $("loading").hidden = true;
  showView();
  if (!fitted) { fitAll(false, true); fitted = true; }
}

$("backbtn").addEventListener("click", () => leave());
$("inspect-outer").addEventListener("click", () => {
  if (!insideOf) return;
  inspectOuter = true;
  scene.selected = null;
  inspector.show(insideOf, outerSnap, { history: true });
});
window.addEventListener("keydown", (e) => { if (e.key === "Escape" && insideOf && !inspector.open) leave(); });

connect({
  onSnapshot,
  onState: (state, detail) => topbar.setState(state, detail),
});

// ---- loop -----------------------------------------------------------------

let lastCam = "";
const stats = { frames: 0, ms: 0, worst: 0 };
window.__obsFactor = { stats, scene };

function frame(now) {
  requestAnimationFrame(frame);
  if (document.hidden) return;
  stepFly(now);
  const animate = scene.motion && snap;
  if (!animate && !dirty) return;
  const t0 = performance.now();
  scene.draw(now);
  const camKey = `${scene.cam.x.toFixed(2)},${scene.cam.y.toFixed(2)},${scene.cam.z.toFixed(4)},${scene.selected},${snap ? snap.at : ""}`;
  if (camKey !== lastCam || dirty) {
    lastCam = camKey;
    if (snap) {
      const top = $("topbar").offsetHeight + ($("attention").hidden ? 0 : $("attention").offsetHeight);
      chips.place((id) => { const a = scene.nodeAnchor(id); return a ? scene.toScreen(a) : null; }, { ...scene.view, top, bottom: 62 }, scene.selected, scene.cam.z);
    }
  }
  const dt = performance.now() - t0;
  stats.frames++; stats.ms += dt; stats.worst = Math.max(stats.worst, dt);
  dirty = false;
}

resize();
requestAnimationFrame(frame);
