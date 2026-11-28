defmodule PortalAPI.Sockets.Connection do
  @moduledoc """
  A device connection over a plain WebSocket, without Phoenix channels.

  Every frame is a JSON text frame `{"event": name, "payload": object}`, in both directions.
  There is no topic, no join, no reply and no heartbeat message:

    * The upgrade request authenticates the device, as on the Phoenix sockets. A refused
      connection gets the same HTTP problem details.
    * The portal sends `init` once the device is connected.
    * The device keeps the connection alive with WebSocket ping frames.
    * The portal closes with 1000 when it ends the session, 1012 when the node drains, 1003 on
      a binary frame and 1007 on a frame that is not a message.

  The connection process runs the channel with `PortalAPI.Channel.Runner`, so that the device's
  state, presence and `Portal.PG` groups belong to the one process that holds the WebSocket.
  This module only adds the framing.
  """

  alias Phoenix.Socket
  alias Phoenix.Socket.{Broadcast, Message}
  alias PortalAPI.Channel.Runner

  @registry __MODULE__.Registry

  @doc "Starts the registry that lists the open connections of each socket module."
  def registry_child_spec do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc "The processes of the open connections of `handler`."
  @spec connections(module()) :: [pid()]
  def connections(handler) do
    for {pid, _value} <- Registry.lookup(@registry, handler), do: pid
  end

  @doc """
  Authenticates the upgrade request with `socket_module.connect/3`, the callback of the
  Phoenix socket at the same path. Once the device is authenticated, `:join_payload` builds
  the payload the channel joins with from the connect info. Without it, the payload is empty.
  """
  def connect(%{endpoint: endpoint, params: params, connect_info: connect_info}, opts) do
    socket = %Socket{
      endpoint: endpoint,
      handler: Keyword.fetch!(opts, :handler),
      channel: Keyword.fetch!(opts, :channel),
      topic: Keyword.fetch!(opts, :topic),
      pubsub_server: endpoint.config(:pubsub_server),
      serializer: __MODULE__,
      transport: :websocket
    }

    join_payload = Keyword.get(opts, :join_payload, fn _connect_info -> {:ok, %{}} end)

    with {:ok, socket} <- Keyword.fetch!(opts, :socket).connect(params, socket, connect_info),
         {:ok, join_payload} <- join_payload.(connect_info) do
      {:ok, %{socket: socket, join_payload: join_payload, stop_reason: nil}}
    end
  end

  def init(%{socket: socket, join_payload: join_payload} = state) do
    {:ok, _owner} = Registry.register(@registry, socket.handler, nil)
    {:ok, socket} = Runner.join(%{socket | transport_pid: self()}, join_payload)
    {:ok, %{state | socket: socket}}
  end

  def handle_in({text, opcode: :text}, state) do
    case decode(text) do
      {:ok, event, payload} -> Runner.handle_in(event, payload, nil, state.socket) |> handle_result(state)
      :error -> {:stop, :normal, 1007, state}
    end
  end

  def handle_in({_data, opcode: :binary}, state) do
    {:stop, :normal, 1003, state}
  end

  def handle_info({:socket_push, opcode, payload}, state) do
    {:push, {opcode, payload}, state}
  end

  def handle_info(%Broadcast{event: "phx_drain"}, state) do
    {:stop, {:shutdown, :restart}, %{state | stop_reason: {:shutdown, :draining}}}
  end

  def handle_info(message, state) do
    Runner.handle_info(message, state.socket) |> handle_result(state)
  end

  def terminate(reason, %{socket: socket, stop_reason: stop_reason}) do
    Runner.terminate(stop_reason || reason, socket)
  end

  @doc false
  # The serializer of the connection's `Phoenix.Socket`: `Phoenix.Channel.push/3` sends the
  # result to the connection process.
  def encode!(%Message{event: event, payload: payload}) do
    {:socket_push, :text, Phoenix.json_library().encode_to_iodata!(%{event: event, payload: payload})}
  end

  defp handle_result({:ok, socket}, state), do: {:ok, %{state | socket: socket}}

  # The channels stop only to end the session. Pushes made right before the stop are still in
  # the mailbox. A `:socket_drain` that `PortalAPI.Channel.Session` sends with the stop is not
  # needed, because the connection closes here.
  defp handle_result({:stop, reason, socket}, state) do
    state = %{state | socket: socket, stop_reason: reason}
    {:stop, :normal, 1000, pending_pushes([]), state}
  end

  defp pending_pushes(acc) do
    receive do
      {:socket_push, opcode, payload} -> pending_pushes([{opcode, payload} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp decode(text) do
    case Phoenix.json_library().decode(text) do
      {:ok, %{"event" => event, "payload" => payload}} when is_binary(event) and is_map(payload) ->
        {:ok, event, payload}

      _other ->
        :error
    end
  end
end
