defmodule PortalAPI.MCPController do
  @moduledoc """
  The MCP endpoint: one stateless POST that speaks JSON-RPC 2.0.

  Rate limiting and request logging are charged exactly once per request by the
  MCP router pipeline. Tool attempts and REST execution outcomes are recorded
  separately on that row. The inner dispatch carries private markers that
  prevent duplicate metering.
  """

  use PortalAPI, :controller

  alias Portal.Scope
  alias PortalAPI.MCP
  alias PortalAPI.MCP.Dispatch
  alias PortalAPI.MCP.Scopes
  alias PortalAPI.MCP.Tool
  alias PortalAPI.MCP.Tools

  @discover_ttl_ms :timer.hours(1)
  @tools_ttl_ms :timer.minutes(5)

  @base64_prefix "=?base64?"
  @base64_suffix "?="

  plug(:validate_origin)

  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, _params) do
    case classify(conn.body_params) do
      {:request, id, method, params} ->
        handle_request(conn, id, method, params)

      {:notification, _method} ->
        send_resp(conn, 202, "")

      :invalid ->
        send_rpc(
          conn,
          400,
          MCP.error(nil, MCP.invalid_request(), "Body is not a JSON-RPC 2.0 request.")
        )
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    send_rpc(
      conn,
      405,
      MCP.error(
        nil,
        MCP.invalid_request(),
        "The MCP endpoint accepts POST only; it does not offer an SSE stream or sessions."
      )
    )
  end

  defp handle_request(conn, id, method, params) do
    conn = PortalAPI.Plugs.MCPRequestLog.identify(conn, method, params)

    with :ok <- validate_params(params),
         :ok <- validate_protocol(conn, method, params) do
      dispatch(conn, id, method, params)
    else
      {:error, status, code, message, data} ->
        send_rpc(conn, status, MCP.error(id, code, message, data))
    end
  end

  # Streamable HTTP clients negotiate once via initialize. No session is needed:
  # subsequent requests identify the negotiated revision in the version header.
  defp dispatch(conn, id, "initialize", %{
         "protocolVersion" => version,
         "capabilities" => capabilities,
         "clientInfo" => %{"name" => name, "version" => client_version}
       })
       when is_binary(version) and is_map(capabilities) and is_binary(name) and
              is_binary(client_version) do
    version = if MCP.legacy_version?(version), do: version, else: MCP.legacy_protocol_version()

    send_rpc(
      conn,
      200,
      MCP.result(id, %{
        protocolVersion: version,
        capabilities: %{tools: %{}},
        serverInfo: MCP.server_info(),
        instructions: MCP.instructions()
      })
    )
  end

  defp dispatch(conn, id, "initialize", _params) do
    send_rpc(conn, 400, MCP.error(id, MCP.invalid_params(), "Invalid initialize parameters."))
  end

  defp dispatch(conn, id, "ping", _params) do
    send_rpc(conn, 200, MCP.result(id, %{}))
  end

  defp dispatch(conn, id, "server/discover", _params) do
    send_rpc(
      conn,
      200,
      MCP.result(id, %{
        supportedVersions: MCP.supported_versions(),
        capabilities: %{tools: %{}},
        instructions: MCP.instructions(),
        ttlMs: @discover_ttl_ms,
        cacheScope: "public"
      })
    )
  end

  defp dispatch(conn, id, "tools/list", params) do
    case Map.get(params, "cursor") do
      nil ->
        tools =
          conn.assigns.subject.credential.scopes
          |> Tools.list()
          |> Enum.map(&Tool.to_definition/1)

        send_rpc(
          conn,
          200,
          MCP.result(id, %{tools: tools, ttlMs: @tools_ttl_ms, cacheScope: "private"})
        )

      _cursor ->
        send_rpc(
          conn,
          400,
          MCP.error(
            id,
            MCP.invalid_params(),
            "This server returns every tool in one page and never issues a cursor."
          )
        )
    end
  end

  defp dispatch(conn, id, "tools/call", params) do
    name = Map.get(params, "name")

    with {:ok, tool} <- fetch_tool(conn, name),
         {:ok, arguments} <- fetch_arguments(params),
         {:ok, status, body, conn} <- Dispatch.call(tool, arguments, conn) do
      send_tool_result(conn, id, status, body)
    else
      {:error, :unknown_tool, message} ->
        send_rpc(conn, 400, MCP.error(id, MCP.invalid_params(), message))

      {:error, :insufficient_scope, scope} ->
        conn
        |> put_resp_header("www-authenticate", MCP.insufficient_scope_challenge(scope))
        |> send_rpc(
          403,
          MCP.error(id, MCP.invalid_request(), "This tool requires the #{scope} scope.")
        )

      {:error, message} when is_binary(message) ->
        send_rpc(conn, 200, MCP.result(id, tool_error(message)))
    end
  end

  defp dispatch(conn, id, method, _params) do
    send_rpc(conn, 404, MCP.error(id, MCP.method_not_found(), "Unknown method: #{method}"))
  end

  defp fetch_arguments(params) do
    case Map.fetch(params, "arguments") do
      :error -> {:ok, %{}}
      {:ok, arguments} when is_map(arguments) -> {:ok, arguments}
      {:ok, _arguments} -> {:error, "tools/call `arguments` must be a JSON object."}
    end
  end

  # A tool that carries no entity cannot be scoped, and is reported the same way
  # as one that does not exist: no scope would unlock it, so naming one would
  # send the client on a pointless authorization round trip.
  defp fetch_tool(conn, name) when is_binary(name) do
    scopes = conn.assigns.subject.credential.scopes

    with {:ok, tool} <- Tools.fetch(name),
         {:ok, required} <- Scopes.required_scope(tool) do
      if Scope.satisfies?(scopes, required) do
        {:ok, tool}
      else
        {:error, :insufficient_scope, required}
      end
    else
      :error -> {:error, :unknown_tool, "Unknown tool: #{name}"}
    end
  end

  defp fetch_tool(_conn, _name) do
    {:error, :unknown_tool, "tools/call requires a string `name`."}
  end

  # An inner 401 means the credential stopped being valid mid-request. Surfacing
  # it as an HTTP 401 lets the client re-authorize rather than hand the model a
  # tool error it cannot act on.
  defp send_tool_result(conn, id, 401, body) do
    send_rpc(conn, 401, MCP.error(id, MCP.invalid_request(), detail(body, "Unauthorized")))
  end

  defp send_tool_result(conn, id, status, body) when status >= 400 do
    send_rpc(conn, 200, MCP.result(id, tool_error(detail(body, "The API request failed."))))
  end

  defp send_tool_result(conn, id, _status, body) do
    send_rpc(
      conn,
      200,
      MCP.result(id, %{
        content: [%{type: "text", text: encode(body)}],
        structuredContent: body,
        isError: false
      })
    )
  end

  defp tool_error(message) do
    %{content: [%{type: "text", text: message}], isError: true}
  end

  defp detail(%{"detail" => detail} = body, _fallback) when is_binary(detail) do
    case Map.get(body, "validation_errors") do
      nil -> detail
      errors -> detail <> " " <> encode(errors)
    end
  end

  defp detail(body, _fallback) when is_map(body), do: encode(body)
  defp detail(_body, fallback), do: fallback

  defp classify(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = body)
       when is_binary(method) and (is_binary(id) or is_integer(id)) do
    {:request, id, method, params(body)}
  end

  defp classify(%{"jsonrpc" => "2.0", "method" => method} = body) when is_binary(method) do
    if Map.has_key?(body, "id"), do: :invalid, else: {:notification, method}
  end

  defp classify(_body), do: :invalid

  defp params(body) do
    Map.get(body, "params", %{})
  end

  defp validate_params(params) when is_map(params) do
    if is_map(Map.get(params, "_meta", %{})), do: :ok, else: invalid_params()
  end

  defp validate_params(_params), do: invalid_params()

  defp invalid_params do
    {:error, 400, MCP.invalid_params(), "`params` and `params._meta` must be JSON objects.", nil}
  end

  defp validate_protocol(_conn, "initialize", _params), do: :ok

  defp validate_protocol(conn, method, params) do
    # A modern metadata envelope must still pass every modern routing check.
    modern? = Map.has_key?(Map.get(params, "_meta", %{}), MCP.protocol_version_key())

    case {modern?, get_req_header(conn, "mcp-protocol-version")} do
      {false, [version]} when version in ["2025-03-26", "2025-06-18", "2025-11-25"] ->
        :ok

      {false, []} when method != "server/discover" ->
        :ok

      _ ->
        with :ok <- validate_protocol_version(conn, params),
             :ok <- validate_header(conn, "mcp-method", method, "Mcp-Method"),
             :ok <- validate_name_header(conn, method, params) do
          validate_client_capabilities(params)
        end
    end
  end

  defp validate_header(conn, header, expected, label) do
    case get_req_header(conn, header) do
      [value] ->
        if decode_header_value(value) == expected do
          :ok
        else
          header_mismatch("#{label} header value does not match the request body.")
        end

      [] ->
        header_mismatch("#{label} header is required.")

      _multiple ->
        header_mismatch("#{label} header must occur exactly once.")
    end
  end

  defp validate_name_header(conn, "tools/call", params) do
    validate_header(conn, "mcp-name", Map.get(params, "name"), "Mcp-Name")
  end

  defp validate_name_header(conn, _method, _params) do
    case get_req_header(conn, "mcp-name") do
      [] -> :ok
      _present -> header_mismatch("Mcp-Name header is valid only for tools/call.")
    end
  end

  # The version is carried twice - in the header for intermediaries, in `_meta`
  # for the server - and the two must agree, so that a gateway routing on the
  # header can never disagree with the server acting on the body.
  defp validate_protocol_version(conn, params) do
    body = get_in(params, ["_meta", MCP.protocol_version_key()])

    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        header_mismatch("MCP-Protocol-Version header is required.")

      [_first, _second | _rest] ->
        header_mismatch("MCP-Protocol-Version header must occur exactly once.")

      [_header] when is_nil(body) ->
        {:error, 400, MCP.invalid_params(),
         "`_meta.#{MCP.protocol_version_key()}` is required on every request.", nil}

      [header] when header != body ->
        header_mismatch("MCP-Protocol-Version header does not match the request body.")

      [_header] ->
        if MCP.supported_version?(body) do
          :ok
        else
          {:error, 400, MCP.unsupported_protocol_version(),
           "Unsupported protocol version: #{body}", %{supported: MCP.supported_versions()}}
        end
    end
  end

  defp validate_client_capabilities(params) do
    if is_map(get_in(params, ["_meta", MCP.client_capabilities_key()])) do
      :ok
    else
      {:error, 400, MCP.invalid_params(),
       "`_meta.#{MCP.client_capabilities_key()}` is required on every request.", nil}
    end
  end

  defp header_mismatch(message) do
    {:error, 400, MCP.header_mismatch(), message, nil}
  end

  # Header values that cannot be carried as plain ASCII arrive Base64 encoded
  # behind a sentinel, and must be decoded before they are compared to the body.
  defp decode_header_value(@base64_prefix <> rest) do
    case String.split(rest, @base64_suffix, parts: 2) do
      [encoded, ""] ->
        case Base.decode64(encoded) do
          {:ok, decoded} -> decoded
          :error -> nil
        end

      _other ->
        @base64_prefix <> rest
    end
  end

  defp decode_header_value(value), do: value

  defp validate_origin(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin] ->
        if allowed_origin?(conn, origin) do
          conn
        else
          conn
          |> send_rpc(
            403,
            MCP.error(nil, MCP.invalid_request(), "Origin #{origin} is not allowed.")
          )
          |> halt()
        end

      _multiple ->
        conn
        |> send_rpc(
          400,
          MCP.error(nil, MCP.header_mismatch(), "Origin header must occur at most once.")
        )
        |> halt()
    end
  end

  # Guards against DNS rebinding: a browser page on another origin must not be
  # able to drive this endpoint with the user's ambient credentials.
  defp allowed_origin?(conn, origin) do
    case URI.parse(origin) do
      %URI{
        scheme: scheme,
        host: host,
        port: port,
        path: path,
        query: nil,
        fragment: nil,
        userinfo: nil
      }
      when is_binary(scheme) and is_binary(host) and path in [nil, ""] ->
        String.downcase(scheme) == conn.scheme |> Atom.to_string() |> String.downcase() and
          String.downcase(host) == String.downcase(conn.host) and
          effective_port(scheme, port) == conn.port

      _other ->
        false
    end
  end

  defp effective_port(scheme, nil), do: URI.default_port(String.downcase(scheme))
  defp effective_port(_scheme, port), do: port

  defp send_rpc(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Phoenix.json_library().encode_to_iodata!(payload))
  end

  # Renders a value as the JSON string that goes inside a text content block,
  # which has to be a binary rather than the iodata the response body takes.
  defp encode(payload), do: Phoenix.json_library().encode!(payload)
end
