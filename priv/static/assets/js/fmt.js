// Formatting. null/undefined is always "-" (unknown), never 0.

export const UNKNOWN = "-";
export const isNum = (v) => typeof v === "number" && Number.isFinite(v);

export function num(v) {
  if (!isNum(v)) return UNKNOWN;
  const a = Math.abs(v);
  if (a === 0) return "0";
  if (a >= 1e9) return `${(v / 1e9).toFixed(a >= 1e10 ? 0 : 1)}G`;
  if (a >= 1e6) return `${(v / 1e6).toFixed(a >= 1e7 ? 0 : 1)}M`;
  if (a >= 1e4) return `${(v / 1e3).toFixed(0)}k`;
  if (a >= 1e3) return `${(v / 1e3).toFixed(1)}k`;
  if (a >= 100) return v.toFixed(0);
  if (a >= 10) return v.toFixed(1).replace(/\.0$/, "");
  if (a >= 1) return v.toFixed(2).replace(/\.?0+$/, "");
  if (a >= 0.01) return v.toFixed(2).replace(/0+$/, "");
  if (a >= 0.001) return v.toFixed(3).replace(/0+$/, "");
  return "<0.001";
}

export function bytes(b) {
  if (!isNum(b)) return UNKNOWN;
  const u = ["B", "KB", "MB", "GB", "TB", "PB"];
  let i = 0, v = b;
  while (Math.abs(v) >= 1000 && i < u.length - 1) { v /= 1024; i++; }
  const s = i === 0 ? String(Math.round(v)) : v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2);
  // trailing zeros of a fraction only: "100" stays 100 (it read "1 MB"
  // for 100 MB, "12 MB" for 120 MB, until 2026-11-22)
  return `${s.includes(".") ? s.replace(/\.?0+$/, "") : s} ${u[i]}`;
}

export function bps(b) { return isNum(b) ? `${bytes(b)}/s` : UNKNOWN; }

export function withUnit(v, unit) {
  if (!isNum(v)) return UNKNOWN;
  if (unit === "bytes") return bytes(v);
  if (unit === "B/s") return bps(v);
  return unit ? `${num(v)} ${unit}` : num(v);
}

export function duration(s) {
  if (!isNum(s)) return UNKNOWN;
  if (s < 90) return `${Math.round(s)} s`;
  if (s < 5400) return `${Math.round(s / 60)} min`;
  if (s < 172800) return `${Math.round(s / 3600)} h`;
  return `${Math.round(s / 86400)} days`;
}

export function utc(d) {
  return d.toISOString().slice(11, 19);
}

export function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
