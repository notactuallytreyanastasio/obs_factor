defmodule ObsFactor.Health do
  @moduledoc """
  Is the observer actually observing? The answer `GET /health` gives and
  the one `ObsFactor.Heartbeat` asks before every ping.

  Healthy means both:

    * the last good snapshot was stored under `max_age_ms` ago (30 s by
      default: six 5 s ticks), and
    * a process is registered as `ObsFactor.Ticker`.

  A process that is up is not enough. A ticker wedged in a slow source, or
  one whose build raises every tick, stays alive while the floor freezes;
  only the age of the last good snapshot catches that.

  Source health is reported as counts and never decides `ok`: one source
  failing is something the floor shows; it is not the observer dying.

  Nothing here names a source, an error message, a URL or a host: `/health`
  is public.
  """

  alias ObsFactor.{Sources, Store}

  @max_age_ms 30_000

  @type t :: %{
          ok: boolean,
          reason: String.t() | nil,
          snapshot_age_s: non_neg_integer | nil,
          sources_ok: non_neg_integer,
          sources_total: non_neg_integer
        }

  def max_age_ms, do: Application.get_env(:obs_factor, :health_max_age_ms, @max_age_ms)

  @doc """
  Options (for tests): `:now` (monotonic ms), `:snapshot_at` (monotonic ms or
  nil), `:ticker_alive` (boolean), `:snapshot` (`Store.snapshot/0`'s value),
  `:sources` (`Sources.all/0`'s value), `:max_age_ms`.
  """
  @spec check(keyword) :: t
  def check(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.monotonic_time(:millisecond) end)
    at = Keyword.get_lazy(opts, :snapshot_at, &Store.snapshot_at/0)
    alive = Keyword.get_lazy(opts, :ticker_alive, &ticker_alive?/0)
    snapshot = Keyword.get_lazy(opts, :snapshot, &store_snapshot/0)
    sources = Keyword.get_lazy(opts, :sources, &sources/0)
    max_age = Keyword.get_lazy(opts, :max_age_ms, &max_age_ms/0)

    age = if at, do: max(now - at, 0)

    reason =
      cond do
        not alive -> "ticker_down"
        age == nil -> "no_snapshot_yet"
        age > max_age -> stale_reason(snapshot)
        true -> nil
      end

    %{
      ok: reason == nil,
      reason: reason,
      snapshot_age_s: age && div(age, 1000),
      sources_ok: Enum.count(sources, fn {_, s} -> s.ok end),
      sources_total: map_size(sources)
    }
  end

  # Stale because every build since has raised, or because no tick has
  # finished at all (wedged).
  defp stale_reason({:error, _}), do: "snapshot_failing"
  defp stale_reason(_), do: "snapshot_stale"

  @doc "One line for a heartbeat body or a log: `ok snapshot_age=3s sources=8/9`."
  def line(%{} = h) do
    age = if h.snapshot_age_s, do: "#{h.snapshot_age_s}s", else: "none"
    head = if h.ok, do: "ok", else: "fail #{h.reason}"
    "#{head} snapshot_age=#{age} sources=#{h.sources_ok}/#{h.sources_total}"
  end

  defp ticker_alive?, do: is_pid(Process.whereis(ObsFactor.Ticker))

  defp store_snapshot do
    if :ets.whereis(Store) == :undefined, do: :none, else: Store.snapshot()
  end

  defp sources do
    if :ets.whereis(Sources) == :undefined, do: %{}, else: Sources.all()
  end
end
