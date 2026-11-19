defmodule ObsFactor.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Validated before anything starts: a bad topology stops the boot with
    # a message naming the entry.
    path =
      Application.get_env(:obs_factor, :topology_path) ||
        raise ObsFactor.Topology.Error,
              "environment variable TOPOLOGY is missing; point it at a topology file, e.g. TOPOLOGY=priv/topology/prod.exs"

    topology = ObsFactor.Topology.load!(path)
    ObsFactor.put_topology(topology)

    if Application.get_env(:obs_factor, :password) == nil do
      Logger.warning("OBS_FACTOR_PASSWORD is not set: every login will fail")
    end

    children =
      [
        ObsFactorWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:obs_factor, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ObsFactor.PubSub},
        ObsFactor.Store,
        {Task.Supervisor, name: ObsFactor.TaskSupervisor},
        ObsFactor.Http,
        ObsFactor.History
      ] ++ collectors(topology) ++ [ObsFactorWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: ObsFactor.Supervisor)
  end

  defp collectors(topology) do
    if Application.get_env(:obs_factor, :start_collectors, true) do
      src = Application.get_env(:obs_factor, :sources, [])
      tick = Application.fetch_env!(:obs_factor, :tick_ms)
      probes = for n <- topology.nodes, n.probe, do: {n.id, n.probe}

      Enum.reject(
        [
          ObsFactor.Postgres.connection_spec(src[:pg_url]),
          {ObsFactor.Collector, {ObsFactor.Docker, interval_ms: tick, url: src[:docker_url]}},
          {ObsFactor.Collector,
           {ObsFactor.Caddy, interval_ms: tick, url: src[:caddy_metrics_url]}},
          {ObsFactor.Collector, {ObsFactor.Postgres, interval_ms: tick, url: src[:pg_url]}},
          {ObsFactor.Collector,
           {ObsFactor.Host, interval_ms: tick, proc: src[:host_proc], disk: src[:host_disk_path]}},
          {ObsFactor.Collector, {ObsFactor.Probes, interval_ms: tick, targets: probes}},
          {ObsFactor.Collector,
           {ObsFactor.Sites,
            interval_ms: Application.fetch_env!(:obs_factor, :sites_interval_ms),
            deadline_ms: 30_000,
            dir: src[:sites_dir]}},
          {ObsFactor.Ticker, tick_ms: tick}
        ],
        &is_nil/1
      )
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ObsFactorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
