defmodule FzHttp.Server do
  @moduledoc """
  Functions for other processes to interact with the FzHttp application
  """

  use GenServer

  alias FzHttp.{Devices, Rules}

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
  def handle_call(:load_peers, _from, _state) do
    reply = {:ok, Devices.to_peer_list()}
    {:reply, reply, nil}
  end

  @impl GenServer
  def handle_call(:load_rules, _from, _state) do
    reply = {:ok, Rules.to_nftables()}
    {:reply, reply, nil}
  end
end
