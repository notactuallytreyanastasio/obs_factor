// identity.js: who this page is signed in as (GET /api/me, ObsFactorWeb.Identity).
//
// Imported first by main.js and awaited at the top level, so every module
// main.js builds afterwards sees it. Under a GitHub login the login is
// written where missions.js, apps_proc.js and processes.js keep the typed
// name ("obs_factor.who"), so they sign with it without asking; the server
// signs with the login anyway, whatever a page sends. Under the password
// login nothing changes: the typed name is the signature.
//
// <html data-via="github|password" data-role="operator|viewer"> lets the CSS
// (identity.css) hide the "change your name" controls under a real login.

const WHO_KEY = "obs_factor.who";

async function load() {
  try {
    const r = await fetch("/api/me", { credentials: "same-origin", headers: { accept: "application/json" } });
    return r.ok ? await r.json() : null;
  } catch {
    return null;
  }
}

export const me = await load();

if (me) {
  document.documentElement.dataset.via = me.via || "";
  document.documentElement.dataset.role = me.role || "";
  if (me.via === "github" && me.login) {
    try { localStorage.setItem(WHO_KEY, me.login); } catch { /* no storage: the server signs with the login anyway */ }
  }
}

/** The login to sign with, or null under the password login. */
export const login = () => (me?.via === "github" ? me.login : null);
export const isOperator = () => !!me?.operator;

// a chip by "Log out": who, and what they may do
function chip() {
  const out = document.querySelector('form[action="/logout"]');
  if (!me || !out || document.getElementById("whoami")) return;
  const el = document.createElement("span");
  el.id = "whoami";
  el.className = `whoami ${me.role || ""}`;
  el.title = me.role === "operator"
    ? "Operator: may act on processes, make tokens and schedule writeups"
    : "Viewer: may look, replay and write up; acting on processes, tokens and schedules are an operator's";
  el.textContent = me.via === "github" ? `${me.login} · ${me.role}` : `password · ${me.role}`;
  out.before(el);
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", chip, { once: true });
else chip();
