defmodule ObsFactor.Deploys do
  @moduledoc """
  What code went out: the `.deployed` file each deploy script writes on the
  box (`/opt/<app>/.deployed`, one line, `<sha>[+dirty]  <ISO time>`), read
  every tick through a read-only bind mount (`/host-opt/<app>/.deployed`
  in the obs-factor container; docs/contract.md "Deploys").

  Which file belongs to which node is the topology's `deployed:` key; a
  node with a `service` and no key is guessed at
  `<DEPLOYED_ROOT>/<service>/.deployed` (`DEPLOYED_ROOT`, default
  `/host-opt`). A guessed file that does not exist is not an error: most
  services have none. A file the topology names that does not exist, or a
  line that does not parse, is: the node carries the error, and nothing is
  made up in its place. `deployed: false` turns the guess off.

  The commit's subject comes from GitHub
  (`GET /repos/<repo>/commits/<sha>`) only when `GITHUB_TOKEN` is set and
  the node has a `repo:` ("owner/name"); otherwise the sha alone. Asked
  once per sha; a failed ask is retried after ten minutes and its error is
  shown, not hidden.

  Every reading not yet kept goes into `deploys` (the objectives database,
  `ObsFactor.Tape.db/0`), one row per node, sha and deploy time, so a
  deploy made while the observer was down is still on the timeline once it
  is back. A new row is broadcast on `ObsFactor.PubSub` topic `"deploys"` as
  `{:deploy, row}`. Without the objectives database the floor still shows
  the current deploy; there is no history.

  Every deploy script on the box writes `.deployed` AFTER it restarts the
  container (and after migrations and the health check), so the restart is
  seen a tick or more before the file changes. `ObsFactor.Wire` pairs them
  within `pair_ms/0`.
  """

  @behaviour ObsFactor.Collector
  require Logger

  alias ObsFactor.Tape

  @topic "deploys"
  @retry_ms 10 * 60_000
  @pair_ms 10 * 60_000
  @gh_timeout 3_000

  @ddl """
  CREATE TABLE IF NOT EXISTS deploys (
    id bigserial PRIMARY KEY,
    node text NOT NULL,
    sha text NOT NULL,
    dirty boolean NOT NULL,
    deployed_at timestamptz NOT NULL,
    subject text,
    repo text,
    seen_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (node, sha, deployed_at)
  )
  """

  def topic, do: @topic

  @doc "How far apart a restart and a changed `.deployed` may be and still be one deploy."
  def pair_ms, do: @pair_ms

  # ---- the collector ---------------------------------------------------------

  @impl true
  def name, do: :deploys

  @impl true
  def init_state(opts) do
    root = Keyword.get(opts, :root) || System.get_env("DEPLOYED_ROOT") || "/host-opt"
    nodes = Keyword.get(opts, :nodes, [])

    %{
      files: files(nodes, root),
      token: Keyword.get_lazy(opts, :github_token, fn -> blank(System.get_env("GITHUB_TOKEN")) end),
      github: Keyword.get(opts, :github, &github/3),
      db: Keyword.get(opts, :db, Tape.db()),
      subjects: %{},
      last: %{},
      kept: MapSet.new()
    }
  end

  @doc """
  `[{node_id, path, named?, repo}]`: the file to read for each node.
  `named?` is true when the topology named it (a missing file is then an
  error), false when it was guessed from the service.
  """
  def files(nodes, root) do
    for n <- nodes, f = file(n, root), f != nil, do: f
  end

  defp file(n, root) do
    repo = Map.get(n, :repo)

    case Map.get(n, :deployed) do
      false -> nil
      path when is_binary(path) -> {n.id, Path.expand(path, root), true, repo}
      nil -> if is_binary(Map.get(n, :service)), do: {n.id, Path.join([root, n.service, ".deployed"]), false, repo}
    end
  end

  @impl true
  def collect(state) do
    readings =
      for {id, path, named?, repo} <- state.files, r = read(path, named?), r != nil, into: %{} do
        {id, Map.merge(r, %{node: id, path: path, repo: repo})}
      end

    {readings, state} = subjects(readings, state)
    state = notice(readings, state)
    state = keep(readings, state)
    {:ok, readings, state}
  end

  # nil: a guessed file that is not there
  defp read(path, named?) do
    case File.read(path) do
      {:ok, body} ->
        case parse(body) do
          {:ok, r} -> r
          {:error, e} -> %{error: "#{path}: #{e}"}
        end

      {:error, :enoent} when not named? ->
        nil

      {:error, reason} ->
        %{error: "#{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  One `.deployed` line: `{:ok, %{sha, dirty, at}}` (`at` unix ms) or
  `{:error, why}`. The deploy scripts write `<sha>[+dirty]  <ISO 8601>`;
  a date alone is midnight UTC.

      iex> ObsFactor.Deploys.parse("9047a85+dirty  2026-11-19T09:22:31Z\\n")
      {:ok, %{sha: "9047a85", dirty: true, at: 1_795_080_151_000}}
  """
  def parse(body) when is_binary(body) do
    line = body |> String.split("\n", trim: true) |> List.first("") |> String.trim()

    with [_, sha, dirty, stamp] <- Regex.run(~r/\A([0-9a-f]{4,40}|unknown)(\+dirty)?\s+(\S+)\z/, line) || {:error, "not \"<sha>[+dirty] <time>\": #{inspect(String.slice(line, 0, 80))}"},
         {:ok, at} <- stamp(stamp) do
      {:ok, %{sha: sha, dirty: dirty == "+dirty", at: at}}
    end
  end

  defp stamp(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        {:ok, DateTime.to_unix(dt, :millisecond)}

      _ ->
        case Date.from_iso8601(s) do
          {:ok, d} -> {:ok, d |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix(:millisecond)}
          _ -> {:error, "#{inspect(s)} is not an ISO 8601 time"}
        end
    end
  end

  # ---- commit subjects ---------------------------------------------------------

  defp subjects(readings, %{token: nil} = state), do: {readings, state}

  defp subjects(readings, state) do
    now = System.system_time(:millisecond)
    fresh? = fn key -> match?({:ok, _}, state.subjects[key]) or match?({:error, _, at} when now - at < @retry_ms, state.subjects[key]) end

    wanted =
      for {_, %{sha: sha, repo: repo}} <- readings, is_binary(repo), sha != "unknown", into: MapSet.new(), do: {repo, sha}

    # asked side by side: five apps asked one after another at boot, each
    # up to 3 s, would outlast the collector's deadline
    ask = Enum.reject(wanted, fresh?)

    asked =
      ask
      |> Task.async_stream(fn {repo, sha} -> state.github.(repo, sha, state.token) end,
        timeout: @gh_timeout + 500, on_timeout: :kill_task)
      |> Enum.zip(ask)
      |> Enum.map(fn
        {{:ok, {:ok, s}}, key} -> {key, {:ok, s}}
        {{:ok, {:error, e}}, key} -> {key, {:error, e, now}}
        {{:exit, r}, key} -> {key, {:error, "GitHub: no answer (#{inspect(r)})", now}}
      end)

    subjects = Map.merge(state.subjects, Map.new(asked))

    readings =
      Map.new(readings, fn
        {id, %{sha: sha, repo: repo} = r} when is_binary(repo) ->
          case subjects[{repo, sha}] do
            {:ok, s} -> {id, Map.put(r, :subject, s)}
            {:error, e, _} -> {id, Map.put(r, :subject_error, e)}
            nil -> {id, r}
          end

        other ->
          other
      end)

    {readings, %{state | subjects: subjects}}
  end

  @doc """
  The first line of the commit's message from GitHub's REST API:
  `{:ok, subject}` or `{:error, why}`. `GITHUB_API_URL` moves it (tests).
  """
  def github(repo, sha, token) do
    base = System.get_env("GITHUB_API_URL") || "https://api.github.com"

    headers = [
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "obs_factor"}
    ]

    case ObsFactor.Http.get("#{base}/repos/#{repo}/commits/#{sha}", timeout: @gh_timeout, headers: headers) do
      {:ok, 200, %{"commit" => %{"message" => m}}, _} when is_binary(m) ->
        {:ok, m |> String.split("\n") |> hd() |> String.trim() |> String.slice(0, 200)}

      # what the box's blog and dave were running on 2026-11-23: deployed
      # from commits that were never pushed
      {:ok, 422, _, _} ->
        {:error, "GitHub has no commit #{sha} in #{repo} (never pushed?)"}

      {:ok, status, body, _} ->
        {:error, "GitHub answered #{status} for #{repo}@#{sha}#{gh_message(body)}"}

      {:error, e} ->
        {:error, "GitHub: #{e}"}
    end
  end

  defp gh_message(%{"message" => m}) when is_binary(m), do: ": " <> m
  defp gh_message(_), do: ""

  # ---- what changed, and what is kept --------------------------------------------

  defp notice(readings, state) do
    last =
      for {id, %{sha: sha} = r} <- readings, into: state.last do
        now = {sha, r.dirty, r.at}

        case state.last[id] do
          prev when prev != nil and prev != now ->
            Logger.info("#{id} deployed #{label(r)}", event: "deploy.seen", node: id, sha: sha, dirty: r.dirty, previous: elem(prev, 0))

          _ ->
            :ok
        end

        {id, now}
      end

    %{state | last: last}
  end

  # every reading not yet in the table; a failed insert is tried again next tick
  defp keep(readings, state) do
    if Process.whereis(state.db) do
      Enum.reduce(readings, state, fn
        {id, %{sha: sha} = r}, st ->
          key = {id, sha, r.at, Map.has_key?(r, :subject)}

          if MapSet.member?(st.kept, key) do
            st
          else
            case insert(r, st.db) do
              {:ok, row} ->
                if row, do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, @topic, {:deploy, row})
                %{st | kept: MapSet.put(st.kept, key)}

              {:error, e} ->
                Logger.warning("deploys: cannot keep #{id} #{sha}: #{Tape.message(e)}", event: "deploy.keep_failed", node: id)
                st
            end
          end

        _, st ->
          st
      end)
    else
      state
    end
  end

  # {:ok, row} for a new deploy, {:ok, nil} for one already kept (its
  # subject filled in if it was missing)
  defp insert(r, db) do
    sql = """
    INSERT INTO deploys (node, sha, dirty, deployed_at, subject, repo) VALUES ($1, $2, $3, $4, $5, $6)
    ON CONFLICT (node, sha, deployed_at) DO UPDATE SET subject = coalesce(deploys.subject, EXCLUDED.subject)
    RETURNING id, node, sha, dirty, deployed_at, subject, repo, (xmax = 0) AS fresh
    """

    with :ok <- ensure(db),
         {:ok, %{rows: [[id, node, sha, dirty, at, subject, repo, fresh]]}} <-
           q(db, sql, [r.node, r.sha, r.dirty, DateTime.from_unix!(r.at, :millisecond), r[:subject], r.repo]) do
      {:ok, if(fresh, do: row(id, node, sha, dirty, at, subject, repo))}
    end
  end

  @doc """
  The deploys kept in `[from, to]` (unix ms), oldest first, at most 2000:
  `{:ok, [%{id, node, sha, dirty, at, subject, repo, url}]}`.
  """
  def list(from_ms, to_ms, db \\ Tape.db()) do
    sql = """
    SELECT * FROM (
      SELECT id, node, sha, dirty, deployed_at, subject, repo FROM deploys
      WHERE deployed_at >= $1 AND deployed_at <= $2 ORDER BY deployed_at DESC LIMIT 2000
    ) d ORDER BY deployed_at, id
    """

    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, sql, [DateTime.from_unix!(from_ms, :millisecond), DateTime.from_unix!(to_ms, :millisecond)]) do
      {:ok, for([id, n, s, d, at, sub, repo] <- rows, do: row(id, n, s, d, at, sub, repo))}
    end
  end

  defp row(id, node, sha, dirty, at, subject, repo),
    do: %{id: id, node: node, sha: sha, dirty: dirty, at: DateTime.to_unix(at, :millisecond), subject: subject, repo: repo, url: url(repo, sha)}

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

  # ---- the snapshot -----------------------------------------------------------------

  @doc """
  Puts `deployed` on every node of a snapshot being built (nil when the
  node has no `.deployed`) and, when there is one, a `deployed` fact the
  inspector shows: `"9047a85+dirty 4d 2h ago · Fix the feed"`. `source`
  is the `:deploys` entry of `ObsFactor.Sources.all/0`, or nil.
  """
  def attach(nodes, source, now_ms) do
    readings = (source && source[:ok] && source[:data]) || %{}

    Enum.map(nodes, fn n ->
      case readings[n.id] do
        nil ->
          Map.put(n, :deployed, nil)

        %{sha: _} = r ->
          d = Map.take(r, [:sha, :dirty, :at, :subject, :subject_error, :repo]) |> Map.put(:url, url(r.repo, r.sha))
          fact = %{label: "deployed", value: "#{label(r)} #{ago(now_ms - r.at)} ago#{if r[:subject], do: " · " <> r.subject, else: ""}"}
          n |> Map.put(:deployed, d) |> Map.update(:facts, [fact], &(&1 ++ [fact]))

        %{error: e} ->
          n
          |> Map.put(:deployed, %{error: e})
          |> Map.update(:facts, [], &(&1 ++ [%{label: "deployed", value: "unreadable: " <> e}]))
      end
    end)
  end

  @doc "`9047a85+dirty`"
  def label(%{sha: sha, dirty: dirty}), do: sha <> if(dirty, do: "+dirty", else: "")

  @doc "The commit on GitHub, when the repo is known and the sha is one."
  def url(repo, sha) when is_binary(repo) and is_binary(sha) and sha != "unknown", do: "https://github.com/#{repo}/commit/#{sha}"
  def url(_, _), do: nil

  @doc "How long ago, as the inspector says it: `40s`, `12m`, `3h 5m`, `4d 2h`."
  def ago(ms) when ms < 0, do: "0s"
  def ago(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  def ago(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  def ago(ms) when ms < 86_400_000, do: "#{div(ms, 3_600_000)}h #{div(rem(ms, 3_600_000), 60_000)}m"
  def ago(ms), do: "#{div(ms, 86_400_000)}d #{div(rem(ms, 86_400_000), 3_600_000)}h"

  defp blank(nil), do: nil
  defp blank(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
end
