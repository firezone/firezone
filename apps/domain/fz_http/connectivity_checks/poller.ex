defmodule FzHttp.ConnectivityChecks.Poller do
  @moduledoc """
  A simple GenServer to periodically check for WAN connectivity by issuing
  POSTs to https://ping[-dev].firez.one/{version}.
  """
  use GenServer
  alias FzHttp.ConnectivityChecks
  require Logger

  # Wait a minute before sending the first ping to avoid event spamming when
  # a container is stuck in a reboot loop.
  @initial_delay 60 * 1_000

  def start_link(request) do
    GenServer.start_link(__MODULE__, request, name: __MODULE__)
  end

  @impl GenServer
  def init(request) do
    :timer.send_after(@initial_delay, :start_interval)
    {:ok, %{request: request}}
  end

  @impl GenServer
  def handle_info(:start_interval, %{request: request} = state) do
    FzHttp.Config.fetch_env!(:fz_http, ConnectivityChecks)
    |> Keyword.fetch!(:interval)
    |> :timer.seconds()
    |> :timer.send_interval(:tick)

    :ok = check_connectivity(request)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:tick, %{request: request} = state) do
    :ok = check_connectivity(request)

    {:noreply, state}
  end

  defp check_connectivity(request) do
    case ConnectivityChecks.check_connectivity(request) do
      {:ok, %ConnectivityChecks.ConnectivityCheck{}} ->
        :ok

      {:error, reason} ->
        Logger.error("An error occurred while performing a connectivity check",
          url: "#{request.scheme}://#{request.host}:#{request.port}#{request.path}",
          reason: inspect(reason)
        )

        :ok
    end
  end
end
