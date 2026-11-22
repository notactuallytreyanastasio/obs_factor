defmodule ObsFactor.Feeds.ObserverViews do
  @moduledoc """
  Feeds of a building's BEAM: `observer:<node_id>:<member or ->:<view>`,
  each fetched through `ObsFactor.ObserverProxy.call/5` (HTTP to the app's
  `/observer/...`, or in-process for node `observer`) on its interval and
  broadcast to every subscriber (docs/contract.md "Observer: a building's
  BEAM, live", "On the bus").

  | view | engine read | every |
  |---|---|---|
  | `system` | `system` | 5 s |
  | `apps` | `apps` | 5 s |
  | `tree:<app>` | `tree/<app>` (depth 8) | 2 s |
  | `procs:<sort>` | `procs?sort=<sort>&limit=50`, and `interval_ms=1000` for `reductions` (ranked by reductions in that second, not since the process started) | 2 s |
  | `proc:<pid>` | `proc/<pid>` | 1 s |
  | `ets` | `ets` | 5 s |
  | `ports` | `ports` | 5 s |

  Intervals can be changed per view with
  `config :obs_factor, :observer_feed_intervals_ms, %{"proc" => 2_000}`
  (keys: system, apps, tree, procs, proc, ets, ports).

  A join is refused (`{:error, reason}`) for a malformed topic, an unknown
  view, a node that is not `observer` or a topology node with a `report`
  URL, a member given for a single node or the observer, no member for a
  clustered node, or a member the reports collector did not read last: the
  pass-through's own checks (`ObsFactor.ObserverProxy.check_target/2`).
  A member that disappears after the join is an error on every fetch.

  `observer:observer:-:beam` is the built-in `ObsFactor.Feeds.Views` feed.
  """
  @behaviour ObsFactor.Feeds.View

  alias ObsFactor.ObserverProxy

  @segment "[A-Za-z0-9_.\\-]{1,200}"
  @topic Regex.compile!("\\Aobserver:(#{@segment}):(#{@segment}):(.+)\\z")
  @sorts ~w(reductions memory message_queue_len)
  @procs_limit 50
  @reductions_window_ms 1_000

  @intervals %{
    "system" => 5_000,
    "apps" => 5_000,
    "tree" => 2_000,
    "procs" => 2_000,
    "proc" => 1_000,
    "ets" => 5_000,
    "ports" => 5_000
  }

  @views "system | apps | tree:<app> | procs:<reductions|memory|message_queue_len> | proc:<pid> | ets | ports"

  @doc """
  `{:ok, node_id, member or nil, view}` for a well-formed observer topic
  (`-` is no member), else `{:error, reason}`. Says nothing about whether
  the node exists.
  """
  def parse(topic) do
    case Regex.run(@topic, topic, capture: :all_but_first) do
      [node, "-", view] ->
        {:ok, node, nil, view}

      [node, member, view] ->
        {:ok, node, member, view}

      nil ->
        {:error,
         "observer topics are observer:<node id>:<member address or ->:<view>, got #{inspect(String.slice(topic, 0, 120))}"}
    end
  end

  @impl true
  def resolve("observer:" <> _ = topic) do
    with {:ok, node, member, view} <- parse(topic),
         {:ok, kind, path, params} <- view(view),
         :ok <- target(node, member) do
      {:ok, {__MODULE__, {node, member, path, params}, interval(kind)}}
    end
  end

  def resolve(_), do: :pass

  defp view(v) when v in ~w(system apps ets ports), do: {:ok, v, [v], %{}}

  defp view("tree:" <> app) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]{0,199}\z/, app),
      do: {:ok, "tree", ["tree", app], %{}},
      else:
        {:error, "tree:<app> needs an application name, got #{inspect(String.slice(app, 0, 60))}"}
  end

  defp view("procs:" <> sort) when sort in @sorts do
    params = %{"sort" => sort, "limit" => Integer.to_string(@procs_limit)}

    params =
      if sort == "reductions",
        do: Map.put(params, "interval_ms", Integer.to_string(@reductions_window_ms)),
        else: params

    {:ok, "procs", ["procs"], params}
  end

  defp view("procs:" <> sort),
    do:
      {:error,
       "procs:<sort> sorts by #{Enum.join(@sorts, ", ")}, not #{inspect(String.slice(sort, 0, 60))}"}

  defp view("proc:" <> pid) do
    if Regex.match?(~r/\A\d{1,10}\.\d{1,10}\.\d{1,10}\z/, pid),
      do: {:ok, "proc", ["proc", pid], %{}},
      else:
        {:error,
         "proc:<pid> needs a pid written 0.123.0, got #{inspect(String.slice(pid, 0, 60))}"}
  end

  defp view(other),
    do: {:error, "no observer view #{inspect(String.slice(other, 0, 60))}: one of #{@views}"}

  defp target(node, member) do
    case ObserverProxy.check_target(node, member) do
      :ok -> :ok
      {_status, %{"error" => e}} -> {:error, e}
    end
  end

  defp interval(kind) do
    Map.merge(@intervals, Application.get_env(:obs_factor, :observer_feed_intervals_ms, %{}))
    |> Map.fetch!(kind)
  end

  @doc """
  One read through the pass-through. `{:ok, body}` for a 200 whose JSON
  carries `node` (every engine answer does); otherwise `{:error, reason}`
  naming the status and the engine's or the pass-through's error.
  """
  def fetch({node, member, path, params}) do
    where = if member, do: "#{node} (#{member})", else: node

    case ObserverProxy.call("GET", node, path, params, member: member) do
      {200, %{"node" => _} = body} ->
        {:ok, body}

      {200, body} ->
        {:error,
         "#{where} answered 200 without \"node\", not an observer engine answer: #{inspect(body, limit: 8) |> String.slice(0, 200)}"}

      {status, %{"error" => e}} ->
        {:error, "#{where} /observer/#{Enum.join(path, "/")} answered #{status}: #{e}"}

      {status, _} ->
        {:error,
         "#{where} /observer/#{Enum.join(path, "/")} answered #{status} without an error message"}
    end
  end
end
