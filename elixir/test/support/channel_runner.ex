defmodule PortalAPI.ChannelCase.Runner do
  @moduledoc """
  Runs a channel in a test process with `PortalAPI.Channel.Runner`, the runner of the plain
  WebSocket connection, in place of `Phoenix.Channel.Server`.

  It keeps the contract of `Phoenix.ChannelTest`: `push/3` reaches the channel, pushes and
  replies reach the test process, the process is linked to the test, and `:sys.get_state/1`
  returns the socket.
  """
  use GenServer

  alias Phoenix.Socket.Message
  alias PortalAPI.Channel.Runner

  @doc "Joins `channel` on `topic` with a socket from `Phoenix.ChannelTest.socket/3`."
  def join(socket, channel, topic) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {self(), %{socket | channel: channel, topic: topic}})
    {:ok, %{}, GenServer.call(pid, :socket)}
  end

  @impl true
  def init({caller, socket}) do
    Process.put(:"$callers", [caller])
    {:ok, Runner.join(socket)}
  end

  @impl true
  def handle_call(:socket, _from, socket), do: {:reply, socket, socket}

  # `Phoenix.ChannelTest.close/2`
  @impl true
  def handle_cast(:close, socket), do: {:stop, {:shutdown, :closed}, socket}

  @impl true
  def handle_info(%Message{event: event, payload: payload, ref: ref}, socket) do
    Runner.handle_in(event, payload, ref, socket) |> result()
  end

  def handle_info(message, socket) do
    Runner.handle_info(message, socket) |> result()
  end

  @impl true
  def terminate(reason, socket), do: Runner.terminate(reason, socket)

  defp result({:ok, socket}), do: {:noreply, socket}
  defp result({:stop, reason, socket}), do: {:stop, reason, socket}
end
