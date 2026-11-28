defmodule PortalAPI.Channel.Runner do
  @moduledoc """
  Runs the callbacks of a channel module in the calling process, without
  `Phoenix.Channel.Server`.

  The channel modules hold the business logic of a device connection. This module drives them
  apart from any transport: the plain WebSocket connection runs it in the process that holds the
  WebSocket, and the channel tests run it in a test process. The transport decides how a push
  reaches the device, because `Phoenix.Channel.push/3` sends the result of the socket's
  `serializer.encode!/1` to its `transport_pid`.

  A transport without replies leaves the socket's `ref` nil, and the runner then drops the
  replies of the channel.
  """
  alias Phoenix.{Channel, Socket}

  @type result :: {:ok, Socket.t()} | {:stop, term(), Socket.t()}

  @doc "Joins the channel of `socket` on its topic with `payload`."
  @spec join(Socket.t(), map()) :: {:ok, Socket.t()} | {:error, term()}
  def join(%Socket{channel: channel, topic: topic} = socket, payload) do
    channel.join(topic, payload, %{socket | channel_pid: self(), joined: true})
  end

  @doc "Handles a message from the device. `ref` is nil when the transport has no replies."
  @spec handle_in(String.t(), map(), term(), Socket.t()) :: result()
  def handle_in(event, payload, ref, %Socket{channel: channel} = socket) do
    channel.handle_in(event, payload, %{socket | ref: ref}) |> result()
  end

  @spec handle_info(term(), Socket.t()) :: result()
  def handle_info(message, %Socket{channel: channel} = socket) do
    channel.handle_info(message, socket) |> result()
  end

  @spec terminate(term(), Socket.t()) :: term()
  def terminate(reason, %Socket{channel: channel} = socket) do
    channel.terminate(reason, socket)
  end

  defp result({:noreply, socket}), do: {:ok, %{socket | ref: nil}}

  defp result({:reply, reply, socket}) do
    reply(socket, reply)
    {:ok, %{socket | ref: nil}}
  end

  defp result({:stop, reason, socket}), do: {:stop, reason, socket}

  defp reply(%Socket{ref: nil}, _reply), do: :ok
  defp reply(socket, reply), do: Channel.reply(Channel.socket_ref(socket), reply)
end
