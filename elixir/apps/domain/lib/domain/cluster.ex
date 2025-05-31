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

    topology_config = [
      default: [
        strategy: adapter,
        config: adapter_config
      ]
    ]

    children =
      if adapter do
        [
          {Cluster.Supervisor, [topology_config, [name: __MODULE__]]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def healthy? do
    config = Domain.Config.fetch_env!(:domain, __MODULE__)
    adapter = Keyword.fetch!(config, :adapter)
    adapter_config = Keyword.fetch!(config, :adapter_config)

    if adapter && adapter_config[:health_check_supported] do
      GenServer.call(adapter, :healthy?)
    else
      true
    end
  end
end
