// A scoped floor: `/?scope=<node id>` shows one building and what it is wired
// to, instead of the whole box. Everything downstream of the snapshot (the
// floor, the attention strip, Sites, the inspector, Processes' sources, the
// jump list) reads the scoped snapshot, so scoping it once in onSnapshot
// scopes them all; Missions filters its list with inScope().
//
// In scope: the building, every node with a belt to or from it, the traffic
// source in front of any proxy among those (so requests still arrive from
// somewhere), and the host's resources (what it runs on). Belts are kept only
// between two nodes in scope: Caddy's belts to the other apps go, its belt to
// this one stays.
//
// Not scoped: Under the hood and Logs are the observer's own VM and log, and
// a fact such as Caddy's total request rate is still the whole proxy's.

export function scopeFromUrl(search = window.location.search) {
  const id = new URLSearchParams(search).get("scope");
  return id && /^[\w.-]{1,80}$/.test(id) ? id : null;
}

// The ids in scope for `id` in snapshot `s`, or null when `id` is not on the
// floor (the caller says so instead of drawing an empty floor).
export function scopeIds(s, id) {
  if (!s.nodes.some((n) => n.id === id)) return null;
  const ids = new Set([id]);
  for (const e of s.edges) {
    if (e.from === id) ids.add(e.to);
    if (e.to === id) ids.add(e.from);
  }
  const kind = new Map(s.nodes.map((n) => [n.id, n.kind]));
  for (const e of s.edges) if (kind.get(e.to) === "proxy" && ids.has(e.to) && kind.get(e.from) === "source") ids.add(e.from);
  for (const n of s.nodes) if (n.kind === "resource") ids.add(n.id);
  return ids;
}

// The snapshot with only the nodes, belts and attention in scope, each
// platform's slots packed so the floor has no empty columns or rows where
// the rest of the box was. Platforms left empty are dropped.
export function scopeSnapshot(s, id) {
  const ids = scopeIds(s, id);
  if (!ids) return { snap: s, missing: true };
  const nodes = s.nodes.filter((n) => ids.has(n.id));
  const packed = new Map();
  for (const p of s.platforms) {
    const on = nodes.filter((n) => n.platform === p.id && Array.isArray(n.pos));
    const cols = [...new Set(on.map((n) => n.pos[0]))].sort((a, b) => a - b);
    const rows = [...new Set(on.map((n) => n.pos[1]))].sort((a, b) => a - b);
    for (const n of on) packed.set(n.id, [cols.indexOf(n.pos[0]), rows.indexOf(n.pos[1])]);
  }
  const scoped = nodes.map((n) => (packed.has(n.id) ? { ...n, pos: packed.get(n.id) } : n));
  const used = new Set(scoped.map((n) => n.platform));
  return {
    missing: false,
    ids,
    snap: {
      ...s,
      nodes: scoped,
      edges: s.edges.filter((e) => ids.has(e.from) && ids.has(e.to)),
      platforms: s.platforms.filter((p) => used.has(p.id)),
      // an attention line with no node is about the observer itself: kept
      attention: (s.attention ?? []).filter((a) => a.node == null || ids.has(a.node)),
      scope: { id, label: s.nodes.find((n) => n.id === id).label, hidden: s.nodes.length - scoped.length },
    },
  };
}
