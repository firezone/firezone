defmodule Domain.Mocks.Cluster.Strategy do
  @moduledoc """
  Mocks for the Cluster.Strategy module.
  """

  def connect_nodes(_topology, _connect, _list_nodes, _nodes) do
    Application.fetch_env!(:domain, :cluster_strategy_reply)
  end
end
