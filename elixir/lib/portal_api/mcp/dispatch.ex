defmodule PortalAPI.MCP.Dispatch do
  @moduledoc """
  Runs a `tools/call` as the REST request it stands for.

  The call is re-entered through `PortalAPI.Router` on a synthetic connection
  carrying the original request's headers and a `PortalAPI.MCP.CaptureAdapter`,
  so the response is captured instead of sent. Everything the REST pipeline
  does still happens, with authentication, metering, and logging shared with
  the outer request. The same controller and view render the result.

  Dispatching this way rather than calling controller actions directly is what
  keeps MCP from becoming a second, subtly different API surface.

  The subject authenticated for the MCP request is handed to the inner one
  rather than being derived again. Re-authenticating would fail outright, since
  an OAuth access token is not a credential the REST pipeline accepts, and even
  where it did work it would stamp the token's last-seen columns twice for one
  request.
  """

  alias PortalAPI.MCP.CaptureAdapter
  alias PortalAPI.MCP.Tool
  alias PortalAPI.Plugs.MCPRequestLog

  @doc """
  Runs `tool` with `arguments` on behalf of the authenticated `conn`.

  Returns the inner response's status, decoded JSON body and audited outer conn, or
  `{:error, reason}` when the arguments cannot be turned into a request.
  """
  def call(%Tool{} = tool, arguments, %Plug.Conn{} = conn) when is_map(arguments) do
    with :ok <- PortalAPI.MCP.Safety.permit(tool),
         :ok <- validate_arguments(tool, arguments) do
      body = build_body(tool, arguments)
      encoded_body = encode_body(body)

      inner = build_conn(tool, arguments, body, encoded_body, conn)

      with :ok <- validate_route(tool, inner) do
        conn = MCPRequestLog.dispatched(conn, inner)
        response = PortalAPI.Router.call(inner, [])
        conn = MCPRequestLog.completed(conn, response.status)
        {:ok, response.status, decode_body(response.resp_body), conn}
      end
    end
  end

  defp validate_arguments(%Tool{} = tool, arguments) do
    known = MapSet.new(tool.path_params ++ tool.query_params ++ tool.body_params)
    provided = MapSet.new(Map.keys(arguments))

    missing = Enum.reject(tool.path_params, &Map.has_key?(arguments, &1))
    unknown = provided |> MapSet.difference(known) |> MapSet.to_list() |> Enum.sort()

    non_scalar =
      Enum.filter(tool.path_params, &(not scalar?(Map.get(arguments, &1)))) ++
        Enum.filter(tool.query_params, &(not optional_scalar?(Map.get(arguments, &1))))

    invalid_ids = Enum.reject(tool.path_params, &valid_identifier?(&1, Map.get(arguments, &1)))

    cond do
      missing != [] ->
        {:error, "missing required argument(s): #{Enum.join(missing, ", ")}"}

      unknown != [] ->
        {:error,
         "unknown argument(s): #{Enum.join(unknown, ", ")}. " <>
           "Accepted arguments are: #{known |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")}"}

      non_scalar != [] ->
        {:error,
         "argument(s) must be a string, number, or boolean: #{Enum.join(non_scalar, ", ")}"}

      invalid_ids != [] ->
        {:error, "path argument(s) must be valid identifiers: #{Enum.join(invalid_ids, ", ")}"}

      true ->
        :ok
    end
  end

  defp scalar?(value) do
    is_binary(value) or is_number(value) or is_boolean(value)
  end

  defp optional_scalar?(value), do: is_nil(value) or scalar?(value)

  # All current path parameters are UUIDs or opaque log IDs. Validate before
  # routing: an empty segment otherwise selects a different (possibly bulk)
  # route before the REST UUID plug gets a chance to examine it.
  defp valid_identifier?("log_id", value), do: Portal.Types.LogId.valid?(value)

  defp valid_identifier?(_name, value) when is_binary(value) do
    byte_size(value) == 36 and match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp valid_identifier?(_name, _value), do: false

  defp validate_route(tool, conn) do
    case Phoenix.Router.route_info(PortalAPI.Router, conn.method, conn.request_path, conn.host) do
      %{plug: controller, plug_opts: action, route: route}
      when controller == tool.controller and action == tool.action and route == tool.route ->
        :ok

      _other ->
        {:error, "Tool arguments do not resolve to the intended REST operation."}
    end
  end

  defp build_conn(%Tool{} = tool, arguments, body, encoded_body, %Plug.Conn{} = conn) do
    path = build_path(tool, arguments)
    query_string = build_query_string(tool, arguments)

    %Plug.Conn{
      conn
      | adapter: {CaptureAdapter, CaptureAdapter.payload(conn)},
        owner: nil,
        method: tool.method |> to_string() |> String.upcase(),
        request_path: path,
        path_info: String.split(path, "/", trim: true),
        path_params: %{},
        query_string: query_string,
        query_params: %Plug.Conn.Unfetched{aspect: :query_params},
        body_params: body,
        params: %Plug.Conn.Unfetched{aspect: :params},
        req_headers: req_headers(conn, encoded_body),
        halted: false,
        state: :unset,
        status: nil,
        resp_body: nil,
        resp_headers: correlation_headers(conn),
        resp_cookies: %{},
        private: inner_private(conn)
    }
  end

  # Endpoint-level state stays (the endpoint, the Ecto sandbox, the session),
  # but everything a dispatch sets for itself is cleared. `put_new_view` in
  # particular keeps whatever view is already there, so leaving the MCP
  # controller's view in place would make every operation render through it.
  # `before_send` callbacks belong to the outer response, not to this one.
  defp inner_private(%Plug.Conn{} = conn) do
    conn.private
    |> Map.put(PortalAPI.Plugs.Auth.subject_key(), conn.assigns.subject)
    |> Map.put(PortalAPI.Plugs.RateLimit.skip_key(), true)
    |> Map.put(PortalAPI.Plugs.RequestLog.skip_key(), true)
    |> Map.drop([
      :before_send,
      :phoenix_action,
      :phoenix_controller,
      :phoenix_format,
      :phoenix_layout,
      :phoenix_pipelines,
      :phoenix_root_layout,
      :phoenix_route,
      :phoenix_template,
      :phoenix_view
    ])
  end

  # The inner request is the same HTTP request, so it keeps the request id the
  # endpoint assigned. Everything else the outer response has set is dropped.
  defp correlation_headers(%Plug.Conn{} = conn) do
    Enum.filter(conn.resp_headers, fn {name, _value} -> name == "x-request-id" end)
  end

  defp build_path(%Tool{} = tool, arguments) do
    Enum.reduce(tool.path_params, tool.path_template, fn name, path ->
      String.replace(path, "{#{name}}", arguments |> Map.fetch!(name) |> to_string() |> URI.encode_www_form())
    end)
  end

  defp build_query_string(%Tool{} = tool, arguments) do
    tool.query_params
    |> Enum.flat_map(fn name ->
      case Map.fetch(arguments, name) do
        {:ok, nil} -> []
        {:ok, value} -> [{name, to_string(value)}]
        :error -> []
      end
    end)
    |> URI.encode_query()
  end

  defp build_body(%Tool{body_params: []}, _arguments), do: %{}

  defp build_body(%Tool{} = tool, arguments) do
    Map.take(arguments, tool.body_params)
  end

  defp encode_body(body) when map_size(body) == 0, do: ""
  defp encode_body(body), do: Phoenix.json_library().encode!(body)

  defp req_headers(%Plug.Conn{} = conn, encoded_body) do
    conn.req_headers
    |> Enum.reject(fn {name, _value} ->
      name in ["accept", "content-type", "content-length"]
    end)
    |> then(
      &[
        {"accept", "application/json"},
        {"content-type", "application/json"},
        {"content-length", encoded_body |> byte_size() |> Integer.to_string()} | &1
      ]
    )
  end

  defp decode_body(nil), do: nil
  defp decode_body(""), do: nil

  defp decode_body(body) do
    case Phoenix.json_library().decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end
end
