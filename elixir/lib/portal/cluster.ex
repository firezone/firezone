defmodule Portal.Cluster do
  @moduledoc """
  Supervisor for Erlang cluster discovery using libcluster.

  Supports running multiple clustering strategies simultaneously, which is useful
  during rolling deploys when migrating between strategies. Configure a secondary
  adapter using `erlang_cluster_adapter_secondary` and its config.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl true
  def init(_opts) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    adapter = Keyword.fetch!(config, :adapter)
    adapter_config = Keyword.fetch!(config, :adapter_config)
    secondary_adapter = Keyword.get(config, :secondary_adapter)
    secondary_adapter_config = Keyword.get(config, :secondary_adapter_config, [])

    topologies =
      build_topologies(adapter, adapter_config, secondary_adapter, secondary_adapter_config)

    children =
      if topologies != [] do
        [{Cluster.Supervisor, [topologies, [name: __MODULE__]]}]
      else
        []
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp build_topologies(nil, _, nil, _), do: []

  defp build_topologies(adapter, adapter_config, nil, _) do
    [default: [strategy: adapter, config: adapter_config]]
  end

  defp build_topologies(nil, _, secondary, secondary_config) do
    [secondary: [strategy: secondary, config: secondary_config]]
  end

  defp build_topologies(adapter, adapter_config, secondary, secondary_config) do
    [
      default: [strategy: adapter, config: adapter_config],
      secondary: [strategy: secondary, config: secondary_config]
    ]
  end
end
