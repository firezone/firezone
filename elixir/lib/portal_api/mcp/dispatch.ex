defmodule PortalAPI.MCP.Dispatch do
  @moduledoc """
  Runs a `tools/call` as the REST request it stands for.

  The call is re-entered through `PortalAPI.Router` on a synthetic connection
  carrying the original request's headers and a `PortalAPI.MCP.CaptureAdapter`,
  so the response is captured instead of sent. Everything the REST pipeline
  does still happens: the bearer token is re-authenticated, the account's rate
  limit is charged, an `api_request_logs` row is written, and the same
  controller and view render the result.

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

  @doc """
  Runs `tool` with `arguments` on behalf of the authenticated `conn`.

  Returns the inner response's status and decoded JSON body, or
  `{:error, reason}` when the arguments cannot be turned into a request.
  """
  def call(%Tool{} = tool, arguments, %Plug.Conn{} = conn) when is_map(arguments) do
    with :ok <- validate_arguments(tool, arguments) do
      body = build_body(tool, arguments)
      encoded_body = encode_body(body)

      response =
        tool
        |> build_conn(arguments, body, encoded_body, conn)
        |> PortalAPI.Router.call([])

      {:ok, response.status, decode_body(response.resp_body)}
    end
  end

  defp validate_arguments(%Tool{} = tool, arguments) do
    known = MapSet.new(tool.path_params ++ tool.query_params ++ tool.body_params)
    provided = MapSet.new(Map.keys(arguments))

    missing = Enum.reject(tool.path_params, &Map.has_key?(arguments, &1))
    unknown = provided |> MapSet.difference(known) |> MapSet.to_list() |> Enum.sort()

    cond do
      missing != [] ->
        {:error, "missing required argument(s): #{Enum.join(missing, ", ")}"}

      unknown != [] ->
        {:error,
         "unknown argument(s): #{Enum.join(unknown, ", ")}. " <>
           "Accepted arguments are: #{known |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")}"}

      true ->
        :ok
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
