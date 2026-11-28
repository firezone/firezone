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

  The connection process runs the callbacks of the channel module itself, so that the device's
  state, presence and `Portal.PG` groups belong to the one process that holds the WebSocket.
  """

  alias Phoenix.Socket
  alias Phoenix.Socket.{Broadcast, Message, Reply}

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
  Phoenix socket at the same path.
  """
  def connect(%{endpoint: endpoint, params: params, connect_info: connect_info}, opts) do
    handler = Keyword.fetch!(opts, :handler)
    channel = Keyword.fetch!(opts, :channel)
    topic = Keyword.fetch!(opts, :topic)

    socket = %Socket{
      endpoint: endpoint,
      handler: handler,
      channel: channel,
      topic: topic,
      pubsub_server: endpoint.config(:pubsub_server),
      serializer: __MODULE__,
      transport: :websocket
    }

    case Keyword.fetch!(opts, :socket).connect(params, socket, connect_info) do
      {:ok, %Socket{} = socket} -> {:ok, %{channel: channel, socket: socket, stop_reason: nil}}
      {:error, reason} -> {:error, reason}
      :error -> :error
    end
  end

  def init(%{channel: channel, socket: socket} = state) do
    {:ok, _owner} = Registry.register(@registry, socket.handler, nil)
    socket = %{socket | transport_pid: self(), channel_pid: self(), joined: true}
    {:ok, socket} = channel.join(socket.topic, %{}, socket)

    {:ok, %{state | socket: socket}}
  end

  def handle_in({text, opcode: :text}, %{channel: channel, socket: socket} = state) do
    case decode(text) do
      {:ok, event, payload} ->
        channel.handle_in(event, payload, socket) |> handle_result(state)

      :error ->
        {:stop, :normal, 1007, state}
    end
  end

  def handle_in({_data, opcode: :binary}, state) do
    {:stop, :normal, 1003, state}
  end

  def handle_info({:socket_push, opcode, payload}, state) do
    {:push, {opcode, payload}, state}
  end

  def handle_info({__MODULE__, :reply}, state) do
    {:ok, state}
  end

  # The channel code sends this when it ends the connection, and right before it returns
  # `{:stop, ...}`, so only a send without a stop reaches here.
  def handle_info(:socket_drain, state) do
    {:stop, {:shutdown, :restart}, state}
  end

  def handle_info(%Broadcast{event: "phx_drain"}, state) do
    {:stop, {:shutdown, :restart}, %{state | stop_reason: {:shutdown, :draining}}}
  end

  def handle_info(message, %{channel: channel, socket: socket} = state) do
    channel.handle_info(message, socket) |> handle_result(state)
  end

  def terminate(reason, %{channel: channel, socket: socket, stop_reason: stop_reason}) do
    channel.terminate(stop_reason || reason, socket)
  end

  @doc false
  # The serializer of the connection's `Phoenix.Socket`: `Phoenix.Channel.push/3` sends the
  # result to the connection process. There are no replies on this protocol.
  def encode!(%Message{event: event, payload: payload}) do
    {:socket_push, :text, Phoenix.json_library().encode_to_iodata!(%{event: event, payload: payload})}
  end

  def encode!(%Reply{}), do: {__MODULE__, :reply}

  defp handle_result({:noreply, socket}, state), do: {:ok, %{state | socket: socket}}
  defp handle_result({:reply, _reply, socket}, state), do: {:ok, %{state | socket: socket}}
  defp handle_result({:stop, reason, _reply, socket}, state), do: handle_result({:stop, reason, socket}, state)

  # Pushes made right before the stop are still in the mailbox.
  defp handle_result({:stop, reason, socket}, state) do
    state = %{state | socket: socket, stop_reason: reason}
    {:stop, :normal, close_code(reason), pending_pushes([]), state}
  end

  defp pending_pushes(acc) do
    receive do
      {:socket_push, opcode, payload} -> pending_pushes([{opcode, payload} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp close_code(reason) when reason in [:normal, :shutdown], do: 1000
  defp close_code({:shutdown, _reason}), do: 1000
  defp close_code(_reason), do: 1011

  defp decode(text) do
    case Phoenix.json_library().decode(text) do
      {:ok, %{"event" => event, "payload" => payload}} when is_binary(event) and is_map(payload) ->
        {:ok, event, payload}

      _other ->
        :error
    end
  end
end
