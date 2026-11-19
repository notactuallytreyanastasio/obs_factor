#!/usr/bin/env bash
# Vendors factory_report into an app that is built from its own source tree
# only (rsynced to a server and built there: no path outside the app, no git).
#
#   packages/factory_report/install.sh <app_dir>
#
# Copies mix.exs, lib/ and README.md to <app_dir>/vendor/factory_report
# (rsync --delete: run it again to update the copy) and prints the lines to
# add by hand. It changes nothing else in the app.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ne 1 ]; then
  echo "usage: $0 <app_dir>" >&2
  exit 2
fi

if [ ! -f "$1/mix.exs" ]; then
  echo "$1 has no mix.exs: not a Mix project" >&2
  exit 1
fi

app_dir="$(cd "$1" && pwd)"
dest="$app_dir/vendor/factory_report"
mkdir -p "$dest"

rsync -a --delete --delete-excluded \
  --include='/mix.exs' --include='/README.md' --include='/lib/' --include='/lib/**' \
  --exclude='*' \
  "$here/" "$dest/"

app="$(grep -Eo '(^|[^a-z_])app:[[:space:]]*:[a-z0-9_]+' "$app_dir/mix.exs" | head -n 1 | sed 's/.*://')"
app="${app:-my_app}"
version="$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' "$here/mix.exs" | head -n 1)"

cat <<TEXT
factory_report $version is in $dest
($(find "$dest" -type f | wc -l | tr -d ' ') files: mix.exs, README.md, lib/). Nothing else was changed.

Add these by hand:

1. mix.exs, in deps:

       {:factory_report, path: "vendor/factory_report"}

   then run \`mix deps.get\` once, so mix.lock has what it needs
   (telemetry, plug, bandit, jason: most Phoenix apps have them already),
   and commit vendor/ and mix.lock.

2. lib/$app/application.ex, in the children list:

       {FactoryReport, app: :$app, port: 9568, token: System.get_env("FACTORY_REPORT_TOKEN")}

   (add \`repos: [YourApp.Repo]\` to count database queries.)

3. Dockerfile, BEFORE the line that runs \`mix deps.get\`:

       COPY vendor vendor

   Typically:

       COPY mix.exs mix.lock ./
       COPY vendor vendor
       RUN mix deps.get --only \$MIX_ENV

   Mix reads vendor/factory_report/mix.exs while resolving dependencies, so
   without that line the build stops at deps.get.

Optional, one JSON object per log line on stdout (config/config.exs):

       config :logger, :default_handler,
         formatter: {FactoryReport.JSONFormatter, %{}}

Then give the observer the URL: report: "http://<service>:9568/report".
The port is for the observer only: do not publish it, do not proxy it.
TEXT

if [ -f "$app_dir/.dockerignore" ] && grep -Eq '^/?vendor(/|$)' "$app_dir/.dockerignore"; then
  echo
  echo "NOTE: $app_dir/.dockerignore excludes vendor: the COPY above will not find it."
fi
