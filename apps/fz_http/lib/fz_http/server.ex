defmodule FzHttp.Server do
  @moduledoc """
  Functions for other processes to interact with the FzHttp application
  """

  use GenServer

  alias FzHttp.{Devices, Devices.StatsUpdater, Rules}

  @process_opts Application.compile_env(:fz_http, :server_process_opts, [])

  def start_link(_) do
    # We're not storing state, simply providing an API
    GenServer.start_link(__MODULE__, nil, @process_opts)
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:load_peers, _from, state) do
    reply = {:ok, Devices.to_peer_list()}
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call(:load_settings, _from, state) do
    reply = {:ok, Rules.to_settings()}
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call({:update_device_stats, stats}, _from, state) do
    {:reply, StatsUpdater.update(stats), state}
  end
end
