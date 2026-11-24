# Connecting an app to the floor

An Elixir app on the box reports its inside to obs_factor through
`packages/factory_report`. Until now, connecting one meant vendoring the
library by hand and adding a node to `priv/topology/prod.exs`, then
redeploying the observer. Now the app's compose service carries a label, and
the observer puts it on the floor at the next tick: no topology edit, no
observer restart.

The page does the typing: **menu → Connect an app**. Give it the OTP app
name, the compose service and the kind; it writes every snippet below for
that app and shows a checklist of what the observer sees, asked again every
5 s while it is open.

```
GET /api/connect?app=ledger&service=ledger&kind=phoenix&label=Ledger&hosts=ledger.bobbby.online&databases=ledger_prod
```

answers `{"input", "report_url", "snippets": [{id, title, file, text, note}], "checklist": [{id, title, state, detail}]}`
(422 `{"error"}` naming the bad field). It is behind the session like the
rest of `/api`.

## The six steps

For an app `ledger` (module `Ledger`), service `ledger`, with a database.

1. **Vendor the library.** From the obs_factor checkout:

   ```sh
   packages/factory_report/install.sh ../ledger
   ```

   It copies the library to `../ledger/vendor/factory_report` and changes
   nothing else. Run it again to update the copy. Commit `vendor/`.

2. **The dependency**, in `mix.exs`, then `mix deps.get` once and commit
   `mix.lock`:

   ```elixir
   {:factory_report, path: "vendor/factory_report"}
   ```

3. **The Dockerfile** copies `vendor/` before `deps.get` (Mix reads
   `vendor/factory_report/mix.exs` while resolving dependencies):

   ```dockerfile
   COPY mix.exs mix.lock ./
   COPY vendor vendor
   RUN mix deps.get --only $MIX_ENV
   ```

4. **The child**, in `lib/ledger/application.ex`, and `++ factory_report()`
   on the children list. This is how blinks_backend runs it on the box:

   ```elixir
   # The report the factory (obs_factor) reads, on :9568 inside
   # the compose network. On in production only (config/prod.exs).
   defp factory_report do
     if Application.get_env(:ledger, :factory_report, false) do
       [{FactoryReport, app: :ledger, port: 9568, repos: [Ledger.Repo], observer: true}]
     else
       []
     end
   end
   ```

   `observer: true` lets the observer read `/observer/...` without a report
   token. Without it the engine answers 403 to every read and the checklist's
   fourth step stays red with that message.

5. **`config/prod.exs`**, so dev and test never bind the port. The second
   line is optional (one JSON object per log line on stdout):

   ```elixir
   config :ledger, factory_report: true

   config :logger, :default_handler, formatter: {FactoryReport.JSONFormatter, %{}}
   ```

6. **The compose service** gets the labels and the actions token:

   ```yaml
     ledger:
       # ... build, image, restart, mem_limit as before ...
       labels:
         obs_factor.report: "http://ledger:9568/report"
         obs_factor.label: "Ledger"
         obs_factor.hosts: "ledger.bobbby.online"
         obs_factor.databases: "ledger_prod"
       environment:
         FACTORY_REPORT_ACTIONS_TOKEN: ${OBS_FACTOR_ACTIONS_TOKEN}
   ```

   Do not publish 9568 and do not route it through Caddy: the report holds
   the app's last log messages.

Deploy the app the way it is deployed today. Nothing on the observer changes.

## The labels

Read from `GET /containers/json`, which the docker-proxy already allows.
Labels never carry secrets.

| label | | |
|---|---|---|
| `obs_factor.report` | required | the factory_report URL; the container is connected when this is present |
| `obs_factor.label` | | the building's name (default: the id) |
| `obs_factor.hosts` | | Caddy hosts, comma separated: the belt from Caddy is metered from them |
| `obs_factor.databases` | | Postgres databases, comma separated: the belt to the db node |
| `obs_factor.platform` | | a platform id from the topology (default: the proxy's platform) |
| `obs_factor.probe` | | an http(s) URL probed like a topology `probe` |
| `obs_factor.id` | | the node id (default: the compose service, lowercased, other characters as `-`) |

A connected node is kind `app`, `pos` `null` (the browser puts it in the
next free slot of its platform). Replicas of a scaled service are one node,
as for a topology entry. A `docker compose run` container never connects.

## The topology wins

`ObsFactor.Discovery` merges the labels with the static topology on every
tick. When a topology node already claims the container (the same compose
`service`, or the same `container` name):

- a field the topology leaves empty (`report`, `probe`, `hosts`,
  `databases`) is filled from the label. So an app that is already in
  `prod.exs` without a `report` starts reporting from its label alone;
- a field the topology sets and the label contradicts keeps the topology's
  value, and the snapshot's `attention` carries a `warn`:

  ```
  container blog-app-1 (node app): obs_factor.report says "http://app:9999/report", the topology says "http://app:9568/report"; the topology wins
  ```

When nothing claims it, it is a node of its own, unless that would break a
topology rule. Each case is a `warn`, never silent:

| what | result |
|---|---|
| the id is taken (another node, or a reserved one) | not placed: the container stays an unplaced node; set `obs_factor.id` |
| a host belongs to another node | that host is left off; the rest are used |
| `obs_factor.platform` is not a platform | placed on the default platform |
| `obs_factor.report` is not an http(s) URL | not placed |
| `obs_factor.probe` is not an http(s) URL | placed, not probed |

## The checklist

| step | green when | |
|---|---|---|
| container | Docker lists a running, non-one-off container with `com.docker.compose.service` = the service | red if it is there and not running |
| floor | the merged topology has a node for it with a report URL | red with Discovery's warning when its labels were refused |
| report | the reports collector read it this round | red with the collector's error |
| observer | `GET /observer` through the pass-through answers 200 | red with the engine's answer (403 without `observer: true`) |
| actions | `OBSERVER_ACTIONS_TOKEN` is set on the observer | waits, never red: reads work without it |

Each step waits on the one before. A report URL that arrived with a label
is read from the collector's next round, so for one tick the node's
`inside.error` is `not read yet: connected by its labels since the last read`.

## Where it reaches

The merged topology (`ObsFactor.Discovery.topology/0`) is what the
snapshot, the reports collector, the probes, the observer pass-through
(`/api/nodes/:id/observer/*`) and the BEAM wire's mailbox poller use. The
wire's per-database headlines (`ObsFactor.Wire`) still read the static
topology: a connected app's databases are on its belt, not yet in those
headlines.

## Not an Elixir app

The labels work for any container that serves the report format
(docs/contract.md, "Reports"). Only Elixir has a library that serves it.
For anything else, `obs_factor.probe` and `obs_factor.hosts` still put the
building on the floor, with the older `obs_factor.id` labels
(docs/contract.md, "Building apps").
