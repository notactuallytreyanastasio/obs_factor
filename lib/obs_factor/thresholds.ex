defmodule ObsFactor.Thresholds do
  @moduledoc """
  Every number that turns a reading into a status or an attention item, in
  one place. Rules that use them live in `ObsFactor.Rules`.
  """

  @doc "A container counts as working on CPU alone above this many cores."
  def working_cpu_cores, do: 0.02

  @doc "How long traffic or CPU keeps a node \"working\" after it stops."
  def working_window_ms, do: 60_000

  @doc "Memory use at or above this fraction of a real limit: within 10% of it."
  def memory_near_limit, do: 0.90

  @doc "Host disk use (df-style used / (used + available)): warn above, alert above."
  def disk_warn, do: 0.85
  def disk_alert, do: 0.95

  @doc "Host memory use (MemTotal - MemAvailable) / MemTotal: warn above."
  def host_memory_warn, do: 0.90

  @doc "Postgres client connections as a fraction of max_connections: alert above."
  def pg_connections_alert, do: 0.90

  @doc "5xx per second for one host: any is a warning, this many is an alert."
  def errors_alert_rps, do: 1.0

  @doc "Restarts inside the restart window: one is a warning, this many a loop."
  def restart_loop_count, do: 3
  def restart_window_label, do: "15 min"
end
