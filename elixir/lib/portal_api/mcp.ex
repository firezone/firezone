defmodule PortalAPI.MCP do
  @moduledoc """
  Model Context Protocol server for the Firezone REST API.

  Implements stateless revision `2026-07-28` and the initialize handshake for
  Streamable HTTP revisions `2025-03-26`, `2025-06-18`, and `2025-11-25`.
  Both use a single POST endpoint without server-side session state.

  Tools are derived from the same `OpenApiSpex` operation specs that generate
  `openapi.json`, and every tool call is dispatched back through
  `PortalAPI.Router`. An MCP tool call and the equivalent REST call therefore
  run the same authentication, rate limiting, request logging, and controller
  code - see `PortalAPI.MCP.Dispatch`.
  """

  @protocol_version "2026-07-28"
  @legacy_versions ["2025-11-25", "2025-06-18", "2025-03-26"]
  @supported_versions [@protocol_version | @legacy_versions]

  @meta_prefix "io.modelcontextprotocol/"
  @protocol_version_key @meta_prefix <> "protocolVersion"
  @client_capabilities_key @meta_prefix <> "clientCapabilities"
  @client_info_key @meta_prefix <> "clientInfo"
  @server_info_key @meta_prefix <> "serverInfo"

  # JSON-RPC 2.0 general failures.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  # Allocated to the MCP specification out of the JSON-RPC implementation-defined
  # range. Never emit an undefined code from -32020..-32099.
  @header_mismatch -32_020
  @missing_required_client_capability -32_021
  @unsupported_protocol_version -32_022

  @doc "The newest protocol revision this server implements."
  def protocol_version, do: @protocol_version

  @doc "Every protocol revision this server accepts on a request."
  def supported_versions, do: @supported_versions

  def legacy_protocol_version, do: hd(@legacy_versions)
  def legacy_version?(version), do: version in @legacy_versions

  def supported_version?(version), do: version in @supported_versions

  def protocol_version_key, do: @protocol_version_key
  def client_capabilities_key, do: @client_capabilities_key
  def client_info_key, do: @client_info_key
  def server_info_key, do: @server_info_key

  def parse_error, do: @parse_error
  def invalid_request, do: @invalid_request
  def method_not_found, do: @method_not_found
  def invalid_params, do: @invalid_params
  def internal_error, do: @internal_error
  def header_mismatch, do: @header_mismatch
  def missing_required_client_capability, do: @missing_required_client_capability
  def unsupported_protocol_version, do: @unsupported_protocol_version

  @doc """
  The canonical URI of this MCP server.

  Defined by the authorization server, which mints tokens for this exact
  audience; this server checks every request against it, so a token issued for
  anything else is refused even while it is otherwise valid.
  """
  defdelegate resource_uri, to: Portal.OAuth

  @doc "Where a client fetches this resource's OAuth metadata."
  def resource_metadata_url do
    resource_uri()
    |> URI.merge(".well-known/oauth-protected-resource/mcp")
    |> URI.to_string()
  end

  @doc "The authorization server that issues tokens for this resource."
  def authorization_server, do: PortalWeb.Endpoint.url()

  @doc """
  The `WWW-Authenticate` value for an unauthenticated request.

  Without it a conforming client has no way to discover where to authenticate,
  and can only report a bare failure.

  No scope is advertised. A client that has none configured then asks for none,
  and the person choosing on the consent screen decides what to grant rather
  than rubber-stamping a list the client picked.
  """
  def challenge do
    ~s(Bearer resource_metadata="#{resource_metadata_url()}")
  end

  @doc "The `WWW-Authenticate` value telling a client which scopes it still needs."
  def insufficient_scope_challenge(required) do
    ~s(Bearer error="insufficient_scope", ) <>
      ~s(scope="#{Portal.Scope.encode(List.wrap(required))}", ) <>
      ~s(resource_metadata="#{resource_metadata_url()}")
  end

  @doc """
  Name and version this server reports as `serverInfo`.

  Self-reported and unverified by the protocol, so it is for display and
  debugging only.
  """
  def server_info do
    %{name: "firezone", version: Application.spec(:portal, :vsn) |> to_string()}
  end

  @doc """
  Guidance handed to the model alongside the tool list.
  """
  def instructions do
    """
    Tools on this server administer a Firezone account through its REST API. \
    Each tool maps to one API operation and acts only within the account the \
    access token belongs to.

    Resources are the things people connect to. Sites group the Gateways that \
    serve them. Policies grant a Group access to a Resource, so access is \
    granted by writing a Policy, never by editing an Actor or a Resource \
    directly. Actors are people or API clients, and Groups collect Actors.

    List operations are paginated: read the cursor from \
    `metadata.next_page` in the response and pass it as `page_cursor` to fetch \
    the next page. Prefer filtering with the documented query parameters over \
    listing everything and filtering afterwards.
    """
  end

  @doc """
  Wraps a successful JSON-RPC result, stamping the fields every result carries.
  """
  def result(id, payload) when is_map(payload) do
    %{
      jsonrpc: "2.0",
      id: id,
      result:
        payload
        |> Map.put(:resultType, "complete")
        |> Map.put(:_meta, %{@server_info_key => server_info()})
    }
  end

  @doc """
  Wraps a JSON-RPC error response. `id` is `nil` when the request was too
  malformed to read one.
  """
  def error(id, code, message, data \\ nil) do
    error = %{code: code, message: message}

    %{
      jsonrpc: "2.0",
      id: id,
      error:
        if data == nil do
          error
        else
          Map.put(error, :data, data)
        end
    }
  end
end
