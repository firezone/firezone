defmodule Portal.Endpoint.Admission do
  @moduledoc """
  Stops the public listener from accepting new connections when the node shuts down.

  Supervise this process after the endpoints that `Portal.Endpoint` dispatches into,
  so that it stops before they do. The inner endpoints then drain their sockets while
  no new connection can reach them. Established connections stay open until
  `Portal.Endpoint` stops.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, Keyword.get(opts, :endpoint, Portal.Endpoint)}
  end

  @impl true
  def terminate(_reason, endpoint) do
    close(endpoint)
  end

  @doc """
  Closes the listening sockets of the endpoint. Established connections stay open.
  """
  def close(endpoint) do
    if Process.whereis(endpoint) do
      for scheme <- [:http, :https],
          {:ok, server} when is_pid(server) <- [Bandit.PhoenixAdapter.bandit_pid(endpoint, scheme)] do
        ThousandIsland.suspend(server)
      end
    end

    :ok
  end
end
