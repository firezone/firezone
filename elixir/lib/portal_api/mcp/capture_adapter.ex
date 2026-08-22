defmodule PortalAPI.MCP.CaptureAdapter do
  @moduledoc """
  A `Plug.Conn.Adapter` that captures a response instead of writing it to a
  socket.

  `PortalAPI.MCP.Dispatch` runs each tool call back through `PortalAPI.Router`.
  That inner request must not touch the real connection, so it is given this
  adapter: the controller renders as usual, and the status, headers, and body
  are read back out of the conn afterwards.

  Only the callbacks a JSON API reaches are implemented. Streaming responses
  raise, because reaching one would mean an operation returned something the
  MCP layer cannot represent, and failing loudly beats truncating it.
  """

  @behaviour Plug.Conn.Adapter

  defstruct peer_data: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil},
            sock_data: %{address: {127, 0, 0, 1}, port: 0},
            ssl_data: nil,
            http_protocol: :"HTTP/1.1"

  @doc "Builds the adapter payload, inheriting connection data from `conn`."
  def payload(%Plug.Conn{} = conn) do
    %__MODULE__{
      peer_data: from_adapter(conn, :get_peer_data, %__MODULE__{}.peer_data),
      sock_data: from_adapter(conn, :get_sock_data, %__MODULE__{}.sock_data),
      ssl_data: from_adapter(conn, :get_ssl_data, nil),
      http_protocol: from_adapter(conn, :get_http_protocol, :"HTTP/1.1")
    }
  end

  @impl Plug.Conn.Adapter
  def send_resp(payload, _status, _headers, body) do
    {:ok, IO.iodata_to_binary(body), payload}
  end

  @impl Plug.Conn.Adapter
  def send_file(_payload, _status, _headers, _path, _offset, _length) do
    raise "PortalAPI.MCP cannot dispatch an operation that responds with send_file/6"
  end

  @impl Plug.Conn.Adapter
  def send_chunked(_payload, _status, _headers) do
    raise "PortalAPI.MCP cannot dispatch an operation that responds with a chunked body"
  end

  @impl Plug.Conn.Adapter
  def chunk(_payload, _body) do
    raise "PortalAPI.MCP cannot dispatch an operation that responds with a chunked body"
  end

  @impl Plug.Conn.Adapter
  def read_req_body(payload, _options), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def push(_payload, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def inform(_payload, _status, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def upgrade(_payload, _protocol, _opts), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{} = payload), do: payload.peer_data

  @impl Plug.Conn.Adapter
  def get_sock_data(%__MODULE__{} = payload), do: payload.sock_data

  @impl Plug.Conn.Adapter
  def get_ssl_data(%__MODULE__{} = payload), do: payload.ssl_data

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{} = payload), do: payload.http_protocol

  defp from_adapter(%Plug.Conn{adapter: {adapter, payload}}, function, default) do
    if function_exported?(adapter, function, 1) do
      apply(adapter, function, [payload])
    else
      default
    end
  rescue
    _error -> default
  end
end
