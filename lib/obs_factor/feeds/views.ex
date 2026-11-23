defmodule ObsFactor.Feeds.Views do
  @moduledoc """
  Which topic is fed by what. The built-in views, each a feed
  (`ObsFactor.Feeds`) of its own:

    * `observer:observer:-:beam` every 2 s: `ObsFactor.Beam.report/1`, the
      observer's own VM, supervision tree, ETS tables and its last 500 log
      events at every level (the panel filters by level itself);
    * `history:<node>:5s` every 15 s and `history:<node>:1m` every 60 s:
      `ObsFactor.History.query/2`, the series behind the inspector's charts;
    * `builds:<job id>` every 2 s: the builder's `GET /builder/api/jobs/:id`
      (the job with the tail of its log), through BUILDER_URL;
    * `builds:<job id>:log` every 2 s: `GET /builder/api/jobs/:id/log`,
      `%{"id", "log"}` with the whole log (the log explorer's).

  Other modules add views by implementing `ObsFactor.Feeds.View` and listing
  themselves in `config :obs_factor, :feed_views` (see `ObsFactor.Feeds`).
  """
  @behaviour ObsFactor.Feeds.View

  @beam_interval_ms 2_000
  @build_interval_ms 2_000

  @doc """
  The spec for `topic`, asking this module first and then every configured
  resolver. `{:error, reason}` when none claims it.
  """
  def spec(topic) when is_binary(topic) do
    [__MODULE__ | Application.get_env(:obs_factor, :feed_views, [])]
    |> Enum.reduce_while(:pass, fn resolver, :pass ->
      case resolver.resolve(topic) do
        :pass -> {:cont, :pass}
        other -> {:halt, other}
      end
    end)
    |> case do
      :pass -> {:error, "no feed serves #{inspect(topic)}"}
      other -> other
    end
  end

  @impl true
  def resolve("observer:observer:-:beam"), do: {:ok, {__MODULE__, :beam, @beam_interval_ms}}

  def resolve("history:" <> rest) do
    case Regex.run(~r/^(.+):(5s|1m)$/, rest, capture: :all_but_first) do
      # any node the history knows, placed by the topology or by labels: an
      # unknown one is a feed that says so on every fetch
      [node, res] ->
        {:ok, {__MODULE__, {:history, node, res}, if(res == "5s", do: 15_000, else: 60_000)}}

      _ ->
        {:error, "history topics are history:<node>:5s or history:<node>:1m"}
    end
  end

  def resolve("builds:" <> rest) do
    case Regex.run(~r/^([a-z0-9-]{1,80})(:log)?$/, rest, capture: :all_but_first) do
      [id] -> {:ok, {__MODULE__, {:build, id, ""}, @build_interval_ms}}
      [id, ":log"] -> {:ok, {__MODULE__, {:build, id, "/log"}, @build_interval_ms}}
      _ -> {:error, "bad build topic: builds:<id> or builds:<id>:log"}
    end
  end

  def resolve(_), do: :pass

  # ---- the fetches -------------------------------------------------------

  def fetch(:beam), do: {:ok, ObsFactor.Beam.report(log_limit: 500)}

  def fetch({:history, node, res}) do
    case ObsFactor.History.query(node, res) do
      {:ok, series} -> {:ok, %{node: node, res: res, series: series}}
      :unknown_node -> {:error, "the observer has no history for #{node}"}
    end
  end

  def fetch({:build, id, suffix}) do
    cfg = ObsFactor.BuilderClient.config()

    case cfg[:url] do
      nil ->
        {:error, "no builder configured (BUILDER_URL)"}

      url ->
        case ObsFactor.BuilderClient.get(url, cfg[:token], "/builder/api/jobs/" <> id <> suffix) do
          {:ok, 200, job} -> {:ok, job}
          {:ok, status, %{"error" => e}} -> {:error, "builder answered #{status}: #{e}"}
          {:ok, status, _} -> {:error, "builder answered #{status}"}
          {:error, msg} -> {:error, "builder: #{msg}"}
        end
    end
  end
end
