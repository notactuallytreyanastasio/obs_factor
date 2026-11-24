defmodule ObsFactor.Heartbeat do
  @moduledoc """
  A dead-man's switch for the observer. With `HEARTBEAT_URL` set, every
  60 s it asks `ObsFactor.Health` whether the observer is observing and, only
  if it is, pings the URL (healthchecks.io, an Uptime Kuma push monitor,
  Better Stack heartbeats, anything that alarms when the pings stop).

  The ping is the absence of a reason to worry, so it is sent only when the
  last good snapshot is under 30 s old and the ticker is registered. A
  wedged ticker, a build that raises every tick, a dead VM and a dead box
  all look the same from outside: the pings stop.

  With `HEARTBEAT_FAIL=1`, an unhealthy check also POSTs `<url>/fail`
  (healthchecks.io and Better Stack both read that path as "down now"),
  which alerts at once instead of after the grace period. Only the path gets
  `/fail`; a query string stays where it was.

  The body is one line (`ObsFactor.Health.line/1`):

      ok snapshot_age=3s sources=8/9

  `HEARTBEAT_METHOD=get` sends a GET without a body, for push URLs that
  only take GET (Uptime Kuma: put `?status=up&msg=OK` in the URL itself).

  Options: `:url` (required), `:method` (`:post` | `:get`), `:fail`
  (boolean), `:interval_ms` (60 000), `:first_after_ms` (20 000: one
  first tick at 5 s plus margin), `:check` (a 0-arity function returning
  `ObsFactor.Health.t()`), `:post` (a function `(method, url, body)` that
  returns `:ok | {:error, message}`; tests pass their own), `:name`.
  """

  use GenServer
  require Logger

  alias ObsFactor.Health

  @doc "The child spec from config, or nil when `HEARTBEAT_URL` is unset."
  def configured_child do
    cfg = Application.get_env(:obs_factor, :heartbeat, [])
    if cfg[:url], do: {__MODULE__, cfg}, else: nil
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Run one beat now (tests); returns what it did."
  def beat(server \\ __MODULE__), do: GenServer.call(server, :beat)

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)

    state = %{
      url: url,
      fail_url: fail_url(url),
      method: Keyword.get(opts, :method, :post),
      fail: Keyword.get(opts, :fail, false),
      interval_ms: Keyword.get(opts, :interval_ms, 60_000),
      check: Keyword.get(opts, :check, &Health.check/0),
      post: Keyword.get(opts, :post, &post/3),
      last: nil
    }

    Process.send_after(self(), :tick, Keyword.get(opts, :first_after_ms, 20_000))

    Logger.info("heartbeat on: every #{div(state.interval_ms, 1000)} s while healthy",
      event: "heartbeat.started",
      fail_variant: state.fail
    )

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval_ms)
    {_did, state} = run(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:beat, _from, state) do
    {did, state} = run(state)
    {:reply, did, state}
  end

  # Never raises: a crashing heartbeat restarted too often would take the
  # observer down with it, which is the opposite of the point.
  defp run(state) do
    did =
      try do
        h = state.check.()
        body = Health.line(h)

        cond do
          h.ok -> {:pinged, deliver(state, state.method, state.url, body)}
          state.fail -> {:failed, deliver(state, :post, state.fail_url, body)}
          true -> {:skipped, h.reason}
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    log(did, state.last)
    {did, %{state | last: kind(did)}}
  end

  defp deliver(state, method, url, body) do
    case state.post.(method, url, body) do
      :ok -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  defp kind({_, {:error, _}}), do: :undelivered
  defp kind({k, _}), do: k

  # Quiet while nothing changes: one line when the heartbeat starts or stops
  # pinging, and every failure to deliver.
  defp log({:pinged, :ok}, :pinged), do: :ok
  defp log({:pinged, :ok}, _), do: Logger.info("heartbeat: pinging", event: "heartbeat.pinging")

  defp log({:skipped, reason}, :skipped), do: Logger.debug("heartbeat skipped: #{reason}")

  defp log({:skipped, reason}, _),
    do:
      Logger.warning("heartbeat stopped: observer unhealthy (#{reason})",
        event: "heartbeat.skipped",
        reason: reason
      )

  defp log({:failed, :ok}, _),
    do: Logger.warning("heartbeat: observer unhealthy, posted /fail", event: "heartbeat.failed")

  defp log({_, {:error, msg}}, _),
    do:
      Logger.warning("heartbeat not delivered: #{msg}",
        event: "heartbeat.undelivered",
        reason: msg
      )

  defp log({:error, msg}, _),
    do: Logger.error("heartbeat check raised: #{msg}", event: "heartbeat.error", reason: msg)

  @doc ~S"""
  `url` with `/fail` appended to its path, query kept.

      iex> ObsFactor.Heartbeat.fail_url("https://hc-ping.com/abc?x=1")
      "https://hc-ping.com/abc/fail?x=1"
  """
  def fail_url(url) do
    uri = URI.parse(url)
    path = String.trim_trailing(uri.path || "", "/") <> "/fail"
    URI.to_string(%{uri | path: path})
  end

  defp post(method, url, body) do
    opts =
      if method == :post,
        do: [body: body, headers: [{"content-type", "text/plain"}]],
        else: []

    case ObsFactor.Http.request(method, url, [timeout: 10_000, decode: false] ++ opts) do
      {:ok, status, _, _} when status in 200..299 -> :ok
      {:ok, status, _, _} -> {:error, "answered #{status}"}
      {:error, msg} -> {:error, msg}
    end
  end
end
