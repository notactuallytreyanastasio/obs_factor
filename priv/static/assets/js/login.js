// The only script on the login page: show why POST /login or the GitHub callback sent us back.
const q = new URLSearchParams(location.search);
const el = document.getElementById("error");
const why = { "1": "Wrong password.", off: "The password login is off: sign in with GitHub.", github: `GitHub sign-in failed: ${q.get("why") || "no reason given"}` }[q.get("error")];
if (why) { el.textContent = why; el.hidden = false; }
// with GitHub and no password form there is nothing to type: no autofocus to miss
if (!document.querySelector(".login-password")) document.querySelector(".login-github")?.focus();
