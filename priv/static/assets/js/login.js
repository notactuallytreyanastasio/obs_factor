// The only script on the login page: show the error when POST /login sent us back.
if (new URLSearchParams(location.search).get("error") === "1") document.getElementById("error").hidden = false;
