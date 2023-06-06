defmodule Domain.Cluster do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl true
  def init(_opts) do
    config = Domain.Config.fetch_env!(:domain, __MODULE__)
    adapter = Keyword.fetch!(config, :adapter)
    adapter_config = Keyword.fetch!(config, :adapter_config)
    pool_opts = Domain.Config.fetch_env!(:domain, :http_client_ssl_opts)

    topology_config = [
      default: [
        strategy: adapter,
        config: adapter_config
      ]
    ]

    shared_children = [
      {Finch, name: __MODULE__.Finch, pools: %{default: pool_opts}}
    ]

    children =
      if adapter != Domain.Cluster.Local do
        [
          {Cluster.Supervisor, [topology_config, [name: __MODULE__]]}
        ]
      else
        []
      end

    Supervisor.init(shared_children ++ children, strategy: :rest_for_one)
  end
end
