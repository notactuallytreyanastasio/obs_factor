// The catalogue (targets.json): loading, validation, the avoid rules, and
// turning command-line selection into a plan of sites -> weighted targets.
//
// Everything that decides WHAT may be requested lives here. Hosts come only
// from the catalogue; a path matching any `avoid` pattern of its host is
// refused, whether it came from the catalogue or from --path.

import { readFileSync } from 'node:fs';

export const KINDS = ['page', 'asset', 'api', 'notfound', 'redirect'];
const HOST_RE = /^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/i;

export class UsageError extends Error {}

export function loadCatalogue(file) {
  let text;
  try {
    text = readFileSync(file, 'utf8');
  } catch (e) {
    throw new UsageError(`cannot read catalogue ${file}: ${e.code || e.message}`);
  }
  let json;
  try {
    json = JSON.parse(text);
  } catch (e) {
    throw new UsageError(`catalogue ${file} is not valid JSON: ${e.message}`);
  }
  return validateCatalogue(json, file);
}

/** Checks the shape strictly (this is a safety tool) and fills defaults. */
export function validateCatalogue(json, name = 'catalogue') {
  const bad = (msg) => { throw new UsageError(`${name}: ${msg}`); };
  if (!json || !Array.isArray(json.sites) || json.sites.length === 0) bad('needs a non-empty "sites" array');
  const sites = json.sites.map((s, i) => {
    const at = `sites[${i}]${s && s.id ? ` (${s.id})` : ''}`;
    if (!s || typeof s !== 'object') bad(`${at} is not an object`);
    if (typeof s.id !== 'string' || !s.id) bad(`${at} needs an "id"`);
    if (typeof s.host !== 'string' || !HOST_RE.test(s.host)) bad(`${at} has a bad "host": ${JSON.stringify(s.host)}`);
    const scheme = s.scheme ?? 'https';
    if (scheme !== 'https' && scheme !== 'http') bad(`${at} scheme must be http or https`);
    if (!Array.isArray(s.paths)) bad(`${at} needs a "paths" array`);
    const paths = s.paths.map((p, j) => {
      const pat = `${at}.paths[${j}]`;
      if (!p || typeof p.path !== 'string') bad(`${pat} needs a "path"`);
      checkPathShape(p.path, pat);
      const weight = p.weight ?? 1;
      if (typeof weight !== 'number' || !Number.isFinite(weight) || weight < 0) bad(`${pat} weight must be a number >= 0`);
      const kind = p.kind ?? 'page';
      if (!KINDS.includes(kind)) bad(`${pat} kind must be one of ${KINDS.join('|')}`);
      return { path: p.path, weight, kind, note: p.note ?? '' };
    });
    const avoid = (s.avoid ?? []).map((a, j) => {
      if (!a || typeof a.pattern !== 'string' || !a.pattern.startsWith('/')) bad(`${at}.avoid[${j}] needs a "pattern" starting with /`);
      return { pattern: a.pattern, why: a.why ?? '' };
    });
    return { id: s.id, label: s.label ?? s.id, host: s.host.toLowerCase(), scheme, paths, avoid };
  });
  return { sites };
}

function checkPathShape(path, where) {
  if (!path.startsWith('/') || path.startsWith('//') || /[\s\\]/.test(path) || /^\/[a-z]+:/i.test(path)) {
    throw new UsageError(`${where}: path must be a plain absolute path like /foo, got ${JSON.stringify(path)}`);
  }
}

// ---------------------------------------------------------------- avoid

/** `*` matches anything (slashes too); everything else is literal; case-insensitive.
 *  A pattern ending in `/*` also matches the bare prefix (`/dtree-ai/*` covers `/dtree-ai`). */
export function avoidMatcher(pattern) {
  const body = pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
  const res = [new RegExp(`^${body}$`, 'i')];
  if (pattern.endsWith('/*')) res.push(new RegExp(`^${pattern.slice(0, -2).replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*')}/?$`, 'i'));
  if (!pattern.includes('*') && !pattern.endsWith('/')) res.push(new RegExp(`^${body}/$`, 'i'));
  return (p) => res.some((r) => r.test(p));
}

/** The spellings a server might treat as the same path: without query,
 *  percent-decoded, slashes collapsed, dot segments resolved. */
export function pathVariants(path) {
  const out = new Set([path]);
  const noQuery = path.split(/[?#]/)[0];
  out.add(noQuery);
  let decoded = noQuery;
  for (let i = 0; i < 3; i++) {
    try {
      const d = decodeURIComponent(decoded);
      if (d === decoded) break;
      decoded = d;
    } catch { break; }
  }
  for (const v of [noQuery, decoded]) {
    const collapsed = v.replace(/\\/g, '/').replace(/\/{2,}/g, '/');
    out.add(collapsed);
    try {
      const resolved = new URL(collapsed, 'http://x.invalid').pathname;
      out.add(resolved);
      out.add(decodeURIComponent(resolved));
    } catch { /* keep what we have */ }
  }
  return [...out];
}

/** host -> [{pattern, why, test}] : the union of every entry's avoid list for that host,
 *  because path routes on a shared host are the same server. */
export function avoidIndex(catalogue) {
  const idx = new Map();
  for (const s of catalogue.sites) {
    const list = idx.get(s.host) ?? [];
    for (const a of s.avoid) list.push({ ...a, test: avoidMatcher(a.pattern) });
    idx.set(s.host, list);
  }
  return idx;
}

/** Returns the avoid rule that forbids host+path, or null. */
export function avoided(idx, host, path) {
  const rules = idx.get(host) ?? [];
  if (!rules.length) return null;
  const vs = pathVariants(path);
  return rules.find((r) => vs.some((v) => r.test(v))) ?? null;
}

// ---------------------------------------------------------------- selection

const splitList = (vals) => (vals ?? []).flatMap((v) => String(v).split(',')).map((s) => s.trim()).filter(Boolean);

/**
 * opts: { all, site[], host[], kind[], pathMatch, path[], weights: 'id=3,id2=1', visit }
 * Returns { sites: [{id, label, share, hosts, targets:[{host, scheme, path, weight, kind, note}]}], warnings[] }
 */
export function buildPlan(catalogue, opts) {
  const ids = splitList(opts.site);
  const hosts = splitList(opts.host).map((h) => h.toLowerCase());
  const kinds = splitList(opts.kind);
  const explicit = splitList(opts.path);
  if (!opts.all && !ids.length && !hosts.length) throw new UsageError('choose what to hit: --site <id>, --host <hostname> or --all');
  const knownIds = new Set(catalogue.sites.map((s) => s.id));
  const knownHosts = new Set(catalogue.sites.map((s) => s.host));
  for (const id of ids) if (!knownIds.has(id)) throw new UsageError(`unknown site id "${id}" (known: ${[...knownIds].join(', ')})`);
  for (const h of hosts) if (!knownHosts.has(h)) throw new UsageError(`host "${h}" is not in the catalogue (hosts come only from the catalogue)`);
  for (const k of kinds) if (!KINDS.includes(k)) throw new UsageError(`unknown kind "${k}" (one of ${KINDS.join('|')})`);
  for (const p of explicit) checkPathShape(p, '--path');

  const idx = avoidIndex(catalogue);
  const warnings = [];
  const groups = new Map();
  for (const s of catalogue.sites) {
    if (ids.length && !ids.includes(s.id)) continue;
    if (hosts.length && !hosts.includes(s.host)) continue;
    const g = groups.get(s.id) ?? { id: s.id, label: s.label, hosts: [], targets: [] };
    if (!g.hosts.includes(s.host)) g.hosts.push(s.host);
    const paths = explicit.length
      ? explicit.map((path) => ({ path, weight: 1, kind: 'page', note: 'from --path' }))
      : s.paths.filter((p) => p.weight > 0
          && (!kinds.length || kinds.includes(p.kind))
          && (!opts.pathMatch || p.path.includes(opts.pathMatch))
          && (!opts.visit || p.kind === 'page'));
    for (const p of paths) {
      const rule = avoided(idx, s.host, p.path);
      if (rule) {
        if (explicit.length) throw new UsageError(`refused: ${s.host}${p.path} matches avoid pattern ${rule.pattern} (${rule.why || 'no reason given'})`);
        warnings.push(`dropped ${s.host}${p.path}: catalogue lists it but it matches avoid ${rule.pattern}`);
        continue;
      }
      g.targets.push({ host: s.host, scheme: s.scheme, ...p });
    }
    groups.set(s.id, g);
  }
  const sites = [];
  for (const g of groups.values()) {
    if (g.targets.length) sites.push(g);
    else warnings.push(`site ${g.id}: no paths left after filters${opts.visit ? ' (visit needs kind "page" paths)' : ''}; skipped`);
  }
  if (!sites.length) throw new UsageError('nothing selected: no paths match the filters');

  const weights = parseWeights(opts.weights);
  for (const id of weights.keys()) if (!sites.some((s) => s.id === id)) throw new UsageError(`--weights names "${id}", which is not among the selected sites`);
  const total = sites.reduce((a, s) => a + (weights.get(s.id) ?? 1), 0);
  for (const s of sites) s.share = (weights.get(s.id) ?? 1) / total;
  return { sites, warnings };
}

export function parseWeights(spec) {
  const m = new Map();
  for (const part of splitList(spec ? [spec] : [])) {
    const [id, w] = part.split('=');
    const n = Number(w);
    if (!id || !(n > 0) || !Number.isFinite(n)) throw new UsageError(`bad --weights entry "${part}" (want id=number, number > 0)`);
    m.set(id.trim(), n);
  }
  return m;
}

/** Weighted pick from items with `weightOf(item)`, using a random in [0,1). */
export function weightedPick(items, weightOf, r) {
  const total = items.reduce((a, it) => a + weightOf(it), 0);
  let x = r * total;
  for (const it of items) {
    x -= weightOf(it);
    if (x < 0) return it;
  }
  return items[items.length - 1];
}

export const pickSite = (plan, r) => weightedPick(plan.sites, (s) => s.share, r);
export const pickTarget = (site, r) => weightedPick(site.targets, (t) => t.weight, r);
