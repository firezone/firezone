defmodule PortalAPI.WebSocketClient do
  @moduledoc """
  A small WebSocket client for tests against a real listener. It speaks just enough of
  RFC 6455 to open a connection, send masked frames and read the server's frames.
  """

  @doc """
  Opens a WebSocket to `path`. Returns `{:ok, socket}` after a 101, or
  `{:error, status, headers, body}` when the server refuses the upgrade.
  """
  def connect(port, path, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request = [
      "GET #{path} HTTP/1.1\r\n",
      "Host: 127.0.0.1:#{port}\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Key: #{key}\r\n",
      "Sec-WebSocket-Version: 13\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {:ok, "HTTP/1.1 " <> <<status::binary-size(3)>> <> _rest} = :gen_tcp.recv(socket, 0, 5_000)
    response_headers = recv_headers(socket, [])
    :ok = :inet.setopts(socket, packet: :raw)

    case String.to_integer(status) do
      101 ->
        {:ok, socket}

      status ->
        body = recv_body(socket, response_headers)
        :gen_tcp.close(socket)
        {:error, status, response_headers, body}
    end
  end

  def send_message(socket, event, payload) do
    send_text(socket, JSON.encode!(%{event: event, payload: payload}))
  end

  def send_text(socket, text), do: send_frame(socket, 0x1, text)
  def send_binary(socket, data), do: send_frame(socket, 0x2, data)
  def send_ping(socket, data), do: send_frame(socket, 0x9, data)

  @doc """
  Reads the next frame: `{:message, event, payload}` for a text frame, `{:pong, data}`, or
  `{:close, code}`. Returns `{:error, reason}` when no frame arrives in time.
  """
  def recv(socket, timeout \\ 5_000) do
    with {:ok, <<_fin::1, _rsv::3, opcode::4, 0::1, len::7>>} <- :gen_tcp.recv(socket, 2, timeout),
         {:ok, len} <- recv_length(socket, len, timeout),
         {:ok, data} <- recv_payload(socket, len, timeout) do
      decode_frame(opcode, data)
    end
  end

  @doc "Reads frames until one is a message with `event`."
  def recv_message(socket, event, timeout \\ 5_000) do
    case recv(socket, timeout) do
      {:message, ^event, payload} -> {:ok, payload}
      {:message, _other, _payload} -> recv_message(socket, event, timeout)
      other -> other
    end
  end

  @doc "Reads frames until one is not a message."
  def recv_control(socket, timeout \\ 5_000) do
    case recv(socket, timeout) do
      {:message, _event, _payload} -> recv_control(socket, timeout)
      other -> other
    end
  end

  def close(socket), do: :gen_tcp.close(socket)

  defp send_frame(socket, opcode, data) do
    mask = :crypto.strong_rand_bytes(4)
    header = <<1::1, 0::3, opcode::4, 1::1, encode_length(byte_size(data))::bitstring>>
    :gen_tcp.send(socket, [header, mask, mask(data, mask)])
  end

  defp encode_length(len) when len < 126, do: <<len::7>>
  defp encode_length(len) when len < 65_536, do: <<126::7, len::16>>
  defp encode_length(len), do: <<127::7, len::64>>

  defp mask(data, mask) do
    key = :binary.copy(mask, div(byte_size(data), 4) + 1)
    :crypto.exor(data, binary_part(key, 0, byte_size(data)))
  end

  defp recv_length(socket, 126, timeout) do
    with {:ok, <<len::16>>} <- :gen_tcp.recv(socket, 2, timeout), do: {:ok, len}
  end

  defp recv_length(socket, 127, timeout) do
    with {:ok, <<len::64>>} <- :gen_tcp.recv(socket, 8, timeout), do: {:ok, len}
  end

  defp recv_length(_socket, len, _timeout), do: {:ok, len}

  defp recv_payload(_socket, 0, _timeout), do: {:ok, <<>>}
  defp recv_payload(socket, len, timeout), do: :gen_tcp.recv(socket, len, timeout)

  defp decode_frame(0x1, data) do
    %{"event" => event, "payload" => payload} = JSON.decode!(data)
    {:message, event, payload}
  end

  defp decode_frame(0x8, <<code::16, _reason::binary>>), do: {:close, code}
  defp decode_frame(0xA, data), do: {:pong, data}

  defp recv_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} ->
        acc

      {:ok, line} ->
        [name, value] = String.split(line, ":", parts: 2)
        recv_headers(socket, [{String.downcase(name), String.trim(value)} | acc])
    end
  end

  defp recv_body(socket, headers) do
    case List.keyfind(headers, "content-length", 0) do
      {_name, "0"} ->
        ""

      {_name, length} ->
        {:ok, body} = :gen_tcp.recv(socket, String.to_integer(length), 5_000)
        body

      nil ->
        ""
    end
  end
end
