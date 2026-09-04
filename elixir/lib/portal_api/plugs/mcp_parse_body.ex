defmodule PortalAPI.Plugs.MCPParseBody do
  @moduledoc """
  Parses MCP JSON while preserving the JSON-RPC error contract.

  Authentication and metering run before this plug. Once a request reaches
  parsing, malformed JSON is therefore answered with the JSON-RPC parse error
  that MCP clients expect rather than the REST API's problem-details shape.
  """

  @behaviour Plug

  import Plug.Conn

  alias PortalAPI.MCP

  @impl Plug
  def init(opts), do: Plug.Parsers.init(opts)

  @impl Plug
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    Plug.Parsers.ParseError ->
      body = MCP.error(nil, MCP.parse_error(), "Parse error")

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Phoenix.json_library().encode_to_iodata!(body))
      |> halt()
  end
end
