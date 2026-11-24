defmodule ObsFactor.Alerts do
  @moduledoc """
  Alerts that go out: when something on the floor breaks, a message to a
  webhook, so nobody has to be watching the screen to know.

  ## What raises one

    * an objective (`ObsFactor.Objectives`) opening, or coming back after it
      cleared itself, at severity `alert`;
    * a BEAM wire item (`ObsFactor.Wire`) with `sev` `"alert"`: a container
      crash, a partition, a stream failing, a logged error, atoms past 80 %
      of the limit, a mailbox of 10 000, Postgres at its connection limit.

  A route with `min_severity` `"warn"` also gets the warnings of both.
  Pins are not sent: a person made them, on the floor.

  When an objective a route was told about clears itself or is crossed
  off, the route gets a resolved message.

  ## Routes

  `alert_routes`, in the objectives database (`ObsFactor.Tape.db/0`): a
  name, a webhook URL, the least severity it wants, optionally only some
  apps, optionally a wire filter set (`ObsFactor.WireFilters`: it narrows
  the route's wire items; objectives are not wire items and pass it),
  quiet hours in UTC (nothing is sent between `quiet_from` and
  `quiet_to`, and nothing is saved for later), the dedup window, enabled.
  The URL is checked by `ObsFactor.WebhookGuard` when saved and when sent.
  It is a secret (a Slack webhook URL is the credential), so `list/1`
  shows a hint of it, and saving a route with a blank URL keeps the one it
  has.

  ## A message

  Slack's incoming webhooks read `text`; the rest is for anything else:

      {"text": "...", "source": "obs_factor", "route": "ops",
       "items": [{"state": "firing" | "resolved", "severity", "source": "objective" | "wire",
                  "kind", "app", "label", "title", "detail", "at", "replay_url",
                  "building_url", "key"}]}

  `replay_url` is `<base>/?t=<iso>`, the tape at that moment;
  `building_url` is `<base>/?scope=<app>`, the floor narrowed to it.

  `ObsFactor.Alerts.Engine` does the listening, grouping and sending.
  """

  alias ObsFactor.{Tape, WebhookGuard}

  @topic "alerts"
  @sevs ~w(alert warn)

  @ddl """
  CREATE TABLE IF NOT EXISTS alert_routes (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    url text NOT NULL,
    min_severity text NOT NULL DEFAULT 'alert' CHECK (min_severity IN ('alert', 'warn')),
    apps text[] NOT NULL DEFAULT '{}',
    filter_id bigint,
    quiet_from integer CHECK (quiet_from BETWEEN 0 AND 23),
    quiet_to integer CHECK (quiet_to BETWEEN 0 AND 23),
    dedup_minutes integer NOT NULL DEFAULT 15 CHECK (dedup_minutes BETWEEN 0 AND 1440),
    enabled boolean NOT NULL DEFAULT true,
    by text,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_sent_at timestamptz,
    last_error text,
    last_error_at timestamptz,
    sent_count integer NOT NULL DEFAULT 0
  )
  """

  @cols "id, name, url, min_severity, apps, filter_id, quiet_from, quiet_to, dedup_minutes, enabled, by, created_at, last_sent_at, last_error, last_error_at, sent_count"

  def topic, do: @topic

  @doc "The engine, when there is an objectives database to keep routes in; nothing when it is nil."
  def child_specs(nil), do: []
  def child_specs(_url), do: [ObsFactor.Alerts.Engine]

  @doc "The dedup window a new route gets, in minutes (ALERT_DEDUP_MINUTES, 15)."
  def default_dedup_minutes, do: Application.get_env(:obs_factor, :alert_dedup_minutes, 15)

  # ---- routes ---------------------------------------------------------------

  @doc "Every route, by name, the URL as a hint. `{:ok, [route]}`."
  def list(db \\ Tape.db()) do
    with {:ok, routes} <- routes(db), do: {:ok, Enum.map(routes, &public/1)}
  end

  @doc "Every route with its URL, for sending. `{:ok, [route]}`."
  def routes(db \\ Tape.db()) do
    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, "SELECT #{@cols} FROM alert_routes ORDER BY lower(name), id", []) do
      {:ok, Enum.map(rows, &row/1)}
    end
  end

  @doc """
  Save a route: `%{"name", "url", "min_severity", "apps", "filter_id",
  "quiet_from", "quiet_to", "dedup_minutes", "enabled", "by"}`; with `"id"`
  to change one (a blank `"url"` keeps its URL). `{:ok, route}`.
  """
  def save(a, db \\ Tape.db()) when is_map(a) do
    id = a["id"]

    with :ok <- ensure(db),
         :ok <- if(is_nil(id) or is_integer(id), do: :ok, else: {:error, "a route id is an integer, got #{inspect(id)}"}),
         {:ok, name} <- text(a["name"], 80, "a route needs a name"),
         {:ok, url} <- url(a["url"], id),
         {:ok, sev} <- if((a["min_severity"] || "alert") in @sevs, do: {:ok, a["min_severity"] || "alert"}, else: {:error, "min_severity is alert or warn"}),
         {:ok, apps} <- apps(a["apps"]),
         {:ok, filter} <- filter_id(a["filter_id"]),
         {:ok, {qf, qt}} <- quiet(a["quiet_from"], a["quiet_to"]),
         {:ok, dedup} <- dedup(if(a["dedup_minutes"] in [nil, ""], do: default_dedup_minutes(), else: a["dedup_minutes"])),
         {:ok, enabled} <- if(a["enabled"] in [nil, true, false], do: {:ok, a["enabled"] != false}, else: {:error, "enabled is true or false"}) do
      by = if is_binary(a["by"]), do: String.slice(String.trim(a["by"]), 0, 60)
      params = [name, sev, apps, filter, qf, qt, dedup, enabled]

      result =
        case id do
          nil ->
            q(db, "INSERT INTO alert_routes (name, min_severity, apps, filter_id, quiet_from, quiet_to, dedup_minutes, enabled, url, by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING #{@cols}", params ++ [url, by])

          id ->
            q(db, "UPDATE alert_routes SET name = $2, min_severity = $3, apps = $4, filter_id = $5, quiet_from = $6, quiet_to = $7, dedup_minutes = $8, enabled = $9, url = coalesce($10, url) WHERE id = $1 RETURNING #{@cols}", [id | params] ++ [url])
        end

      case result do
        {:ok, %{rows: [r]}} -> {:ok, r |> row() |> public()}
        {:ok, %{rows: []}} -> {:error, "no route #{id}: deleted already?"}
        {:error, e} -> {:error, Tape.message(e)}
      end
    end
  end

  def delete(id, db \\ Tape.db())

  def delete(id, db) when is_integer(id) do
    with :ok <- ensure(db),
         {:ok, %{num_rows: 1}} <- q(db, "DELETE FROM alert_routes WHERE id = $1", [id]) do
      {:ok, id}
    else
      {:ok, %{num_rows: 0}} -> {:error, "no route #{id}"}
      {:error, e} -> {:error, Tape.message(e)}
    end
  end

  def delete(id, _), do: {:error, "a route id is an integer, got #{inspect(id)}"}

  @doc "Record a delivery: `:ok` stamps `last_sent_at`, `{:error, e}` stamps `last_error`."
  def record(id, result, db \\ Tape.db())

  def record(id, :ok, db),
    do: q(db, "UPDATE alert_routes SET last_sent_at = now(), sent_count = sent_count + 1, last_error = NULL WHERE id = $1", [id])

  def record(id, {:error, e}, db),
    do: q(db, "UPDATE alert_routes SET last_error = $2, last_error_at = now() WHERE id = $1", [id, String.slice(Tape.message(e), 0, 500)])

  @doc "The routes, to everyone on the `alerts` topic."
  def broadcast(db \\ Tape.db()) do
    with {:ok, l} <- list(db), do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, @topic, {:alert_routes, l})
    :ok
  end

  @doc """
  Send a test message to a route now, whatever its filters and quiet
  hours, once (no retry: the person is watching). The result is recorded
  on the route. `:ok` or `{:error, reason}`.
  """
  def test_send(id, opts \\ []) do
    db = Keyword.get(opts, :db, Tape.db())
    post = Keyword.get(opts, :post, &WebhookGuard.post/2)
    base = Keyword.get(opts, :base_url) || ObsFactorWeb.Endpoint.url()

    with {:ok, routes} <- routes(db),
         %{} = r <- Enum.find(routes, &(&1.id == id)) || {:error, "no route #{inspect(id)}"} do
      now = System.system_time(:millisecond)

      item = %{state: "test", severity: "alert", source: "test", kind: "test", app: nil, label: nil, key: "test",
               title: "a test message from obs_factor", detail: "route #{r.name}: if you can read this, alerts reach you", at: now}

      result = post.(r.url, message(r, [item], base))
      record(r.id, result, db)
      broadcast(db)
      result
    end
  end

  # ---- what a route gets ----------------------------------------------------

  @doc """
  Does `item` (an `ObsFactor.Alerts.Engine` item) go to `route`? Its
  severity, its app, and for a wire item the route's filter spec (`spec`:
  a `ObsFactor.WireFilters` spec, or nil).
  """
  def wants?(route, item, spec \\ nil) do
    sev_ok = item.severity == "alert" or (item.severity == "warn" and route.min_severity == "warn")
    app_ok = route.apps == [] or item.app in route.apps
    sev_ok and app_ok and (item.source != "wire" or spec_matches?(spec, item))
  end

  @doc "Does a wire filter spec let this wire item through? (as board.js applies it)"
  def spec_matches?(nil, _), do: true

  def spec_matches?(spec, item) do
    in_list = fn list, v -> list in [nil, []] or v in list end
    q = String.downcase(spec["q"] || "")
    hay = String.downcase(Enum.join([item.title, item.detail, item[:member]] |> Enum.reject(&is_nil/1), " "))

    in_list.(spec["apps"], item.app) and in_list.(spec["sevs"], item.severity) and in_list.(spec["kinds"], item.kind) and
      (q == "" or String.contains?(hay, q))
  end

  @doc "Is `now_ms` inside the route's quiet hours (UTC)? `from` 22, `to` 7: 22:00 to 06:59."
  def quiet?(%{quiet_from: f, quiet_to: t}, now_ms) when is_integer(f) and is_integer(t) and f != t do
    h = now_ms |> div(3_600_000) |> rem(24)
    if f < t, do: h >= f and h < t, else: h >= f or h < t
  end

  def quiet?(_, _), do: false

  @doc "The JSON body for one route and its items, `text` for Slack."
  def message(route, items, base) do
    items = Enum.map(items, &with_links(&1, base))
    firing = Enum.count(items, &(&1.state == "firing"))
    resolved = Enum.count(items, &(&1.state == "resolved"))

    head =
      cond do
        Enum.any?(items, &(&1.state == "test")) -> "obs_factor: test"
        true -> "obs_factor: " <> Enum.join(Enum.reject([count(firing, "firing"), count(resolved, "resolved")], &is_nil/1), ", ")
      end

    lines =
      Enum.map(items, fn i ->
        tag = case i.state do "resolved" -> "RESOLVED"; "test" -> "TEST"; _ -> String.upcase(i.severity) end
        who = if i.label || i.app, do: "#{i.label || i.app}: ", else: ""
        links = Enum.reject([i.replay_url && "<#{i.replay_url}|replay #{clock(i.at)} UTC>", i.building_url && "<#{i.building_url}|building>"], &is_nil/1)

        "*[#{tag}]* #{who}#{i.title}" <>
          if(i.detail not in [nil, ""], do: "\n    #{i.detail}", else: "") <>
          if(links != [], do: "\n    " <> Enum.join(links, " · "), else: "")
      end)

    %{
      text: Enum.join([head | lines], "\n"),
      source: "obs_factor",
      route: route.name,
      items: Enum.map(items, fn i -> i |> Map.take([:state, :severity, :source, :kind, :app, :label, :title, :detail, :replay_url, :building_url, :key]) |> Map.put(:at, iso(i.at)) end)
    }
  end

  defp with_links(i, base) do
    Map.merge(i, %{
      replay_url: if(i.state != "test", do: "#{base}/?t=#{iso(i.at)}"),
      building_url: if(is_binary(i.app), do: "#{base}/?scope=#{URI.encode_www_form(i.app)}")
    })
  end

  defp count(0, _), do: nil
  defp count(n, what), do: "#{n} #{what}"

  # ---- rows -----------------------------------------------------------------

  defp row([id, name, url, sev, apps, filter, qf, qt, dedup, enabled, by, created, sent, err, err_at, n]) do
    %{id: id, name: name, url: url, min_severity: sev, apps: apps, filter_id: filter, quiet_from: qf, quiet_to: qt,
      dedup_minutes: dedup, enabled: enabled, by: by, created_at: ms(created), last_sent_at: ms(sent), last_error: err,
      last_error_at: ms(err_at), sent_count: n}
  end

  # the URL is the credential: the page sees where it goes, not the path
  defp public(r) do
    hint =
      case URI.parse(r.url) do
        %URI{scheme: s, host: h, path: p} when is_binary(p) and byte_size(p) > 4 -> "#{s}://#{h}/…#{String.slice(p, -4, 4)}"
        %URI{scheme: s, host: h} -> "#{s}://#{h}/"
      end

    r |> Map.delete(:url) |> Map.put(:url_hint, hint)
  end

  defp url(u, id) when u in [nil, ""] and is_integer(id), do: {:ok, nil}
  defp url(u, _) when u in [nil, ""], do: {:error, "a route needs a webhook URL"}
  defp url(u, _), do: WebhookGuard.check(u)

  defp apps(nil), do: {:ok, []}

  defp apps(l) when is_list(l) and length(l) <= 50 do
    if Enum.all?(l, &(is_binary(&1) and byte_size(&1) in 1..80)), do: {:ok, Enum.uniq(l)}, else: {:error, "apps: node ids"}
  end

  defp apps(_), do: {:error, "apps: a list of node ids"}

  defp filter_id(nil), do: {:ok, nil}
  defp filter_id(""), do: {:ok, nil}
  defp filter_id(i) when is_integer(i), do: {:ok, i}
  defp filter_id(_), do: {:error, "filter_id is a wire filter set id"}

  defp quiet(f, t) when f in [nil, ""] and t in [nil, ""], do: {:ok, {nil, nil}}
  defp quiet(f, t) when is_integer(f) and is_integer(t) and f in 0..23 and t in 0..23, do: {:ok, {f, t}}
  defp quiet(_, _), do: {:error, "quiet hours are two hours, 0 to 23 (UTC), or none"}

  defp dedup(m) when is_integer(m) and m in 0..1440, do: {:ok, m}
  defp dedup(_), do: {:error, "dedup_minutes is 0 to 1440"}

  defp text(t, max, msg) when is_binary(t) do
    case String.trim(t) do
      "" -> {:error, msg}
      v -> {:ok, String.slice(v, 0, max)}
    end
  end

  defp text(_, _, msg), do: {:error, msg}

  defp ensure(db) do
    case q(db, @ddl, []) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp q(db, sql, params) do
    Postgrex.query(db, sql, params)
  catch
    :exit, reason -> {:error, reason}
  end

  defp ms(nil), do: nil
  defp ms(%DateTime{} = d), do: DateTime.to_unix(d, :millisecond)

  defp iso(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(_), do: nil

  defp clock(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  defp clock(_), do: ""
end
