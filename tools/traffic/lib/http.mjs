// Sending one request, with node:http/https (fetch forbids setting Host, which
// --base needs). Only GET and HEAD can leave this module. Redirects are never
// followed here; the engine decides (and only to catalogue hosts).

import http from 'node:http';
import https from 'node:https';
import { performance } from 'node:perf_hooks';
import { UsageError } from './catalogue.mjs';

export const USER_AGENT = 'obs-factor-traffic/1 (owner load test)';
export const ALLOWED_METHODS = new Set(['GET', 'HEAD']);
const MAX_BODY = 2 * 1024 * 1024; // kept for HTML parsing; the rest is drained and counted

/** --base must be a loopback http(s) URL: it exists for the lab and local stubs. */
export function parseBase(base) {
  if (base == null) return null;
  let u;
  try { u = new URL(base); } catch { throw new UsageError(`--base ${base} is not a URL`); }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new UsageError('--base must be http:// or https://');
  const h = u.hostname.replace(/^\[|\]$/g, '');
  if (!(h === 'localhost' || h === '::1' || /^127\.\d+\.\d+\.\d+$/.test(h))) {
    throw new UsageError(`--base must point at this machine (localhost/127.x/::1), got ${u.hostname}`);
  }
  if (u.search || u.hash) throw new UsageError('--base takes no query or fragment');
  return u;
}

/** --map prod=lab pairs; keys must be catalogue hosts; only meaningful with --base. */
export function parseMap(values, catalogueHosts, base) {
  const m = new Map();
  for (const part of (values ?? []).flatMap((v) => String(v).split(',')).filter(Boolean)) {
    const [from, to] = part.split('=').map((s) => s?.trim().toLowerCase());
    if (!from || !to) throw new UsageError(`bad --map "${part}" (want prodhost=labhost)`);
    if (!catalogueHosts.has(from)) throw new UsageError(`--map ${from}: not a catalogue host`);
    m.set(from, to);
  }
  if (m.size && !base) throw new UsageError('--map only works with --base (without it, hosts come straight from the catalogue)');
  return m;
}

/**
 * Returns send({method, scheme, host, path, wantBody}) -> Promise<{status, ms, bytes, body?, location?, error?}>.
 * status 0 means no HTTP response (connection error or timeout). Never rejects for
 * network trouble; throws synchronously for anything unsafe.
 */
export function makeSender({ base = null, map = new Map(), timeoutMs = 10000, concurrency = 8 } = {}) {
  const agents = {
    'http:': new http.Agent({ keepAlive: true, maxSockets: concurrency }),
    'https:': new https.Agent({ keepAlive: true, maxSockets: concurrency }),
  };
  const live = new Set();

  function send({ method = 'GET', scheme = 'https', host, path, wantBody = false }) {
    if (!ALLOWED_METHODS.has(method)) throw new Error(`refusing method ${method}: only GET and HEAD`);
    if (typeof path !== 'string' || !path.startsWith('/') || path.startsWith('//')) throw new Error(`refusing path ${path}`);
    const hostHeader = map.get(host) ?? host;
    let protocol, hostname, port, prefix = '';
    if (base) {
      protocol = base.protocol;
      hostname = base.hostname.replace(/^\[|\]$/g, '');
      port = base.port || undefined;
      prefix = base.pathname.replace(/\/$/, '');
    } else {
      protocol = `${scheme}:`;
      hostname = host;
    }
    const lib = protocol === 'https:' ? https : http;
    const opts = {
      method, hostname, port, path: prefix + path, agent: agents[protocol],
      headers: { Host: hostHeader, 'User-Agent': USER_AGENT, Accept: wantBody ? 'text/html,*/*;q=0.8' : '*/*', 'Accept-Encoding': 'identity' },
    };
    if (protocol === 'https:') opts.servername = hostHeader;

    return new Promise((resolve) => {
      const t0 = performance.now();
      let done = false;
      const finish = (r) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        live.delete(req);
        resolve({ ms: performance.now() - t0, ...r });
      };
      const req = lib.request(opts, (res) => {
        const chunks = [];
        let bytes = 0;
        res.on('data', (c) => {
          bytes += c.length;
          if (wantBody && bytes <= MAX_BODY) chunks.push(c);
        });
        res.on('end', () => finish({
          status: res.statusCode, bytes, location: res.headers.location,
          contentType: res.headers['content-type'] ?? '',
          body: wantBody ? Buffer.concat(chunks).toString('utf8') : undefined,
        }));
        res.on('error', (e) => finish({ status: 0, bytes, error: e.code || e.message }));
      });
      const timer = setTimeout(() => { req.destroy(Object.assign(new Error('timeout'), { code: 'TIMEOUT' })); }, timeoutMs);
      req.on('error', (e) => finish({ status: 0, bytes: 0, error: e.code || e.message }));
      live.add(req);
      req.end();
    });
  }

  send.close = () => {
    for (const r of live) r.destroy(Object.assign(new Error('stopped'), { code: 'STOPPED' }));
    agents['http:'].destroy();
    agents['https:'].destroy();
  };
  return send;
}

/**
 * Same-origin assets a browser would fetch for this page: <script src>,
 * <img src>, <link href> for stylesheets/icons/preloads. Returns paths
 * (pathname+search), deduplicated, at most `limit`.
 */
export function extractAssets(html, pageUrl, sameOriginHosts, limit = 12) {
  const out = [];
  const seen = new Set();
  const tagRe = /<(script|img|link)\b([^>]*)>/gi;
  let m;
  while ((m = tagRe.exec(html)) && out.length < limit) {
    const tag = m[1].toLowerCase();
    const attrs = m[2];
    if (tag === 'link') {
      const rel = attr(attrs, 'rel') ?? '';
      if (!/\b(stylesheet|icon|preload|modulepreload|apple-touch-icon)\b/i.test(rel)) continue;
    }
    const val = attr(attrs, tag === 'link' ? 'href' : 'src');
    if (!val) continue;
    let u;
    try { u = new URL(val.trim(), pageUrl); } catch { continue; }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') continue;
    if (!sameOriginHosts.has(u.hostname.toLowerCase())) continue;
    const p = u.pathname + u.search;
    if (p.startsWith('//') || seen.has(p)) continue;
    seen.add(p);
    out.push(p);
  }
  return out;
}

function attr(attrs, name) {
  const m = new RegExp(`(?:^|\\s)${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'>]+))`, 'i').exec(attrs);
  return m ? (m[1] ?? m[2] ?? m[3]) : null;
}
