defmodule PortalAPI.Plugs.MCPRequestLog do
  @moduledoc """
  Enriches an MCP request's existing audit row with its REST operation.

  The row is inserted before body parsing, ensuring malformed and oversized
  requests are still audited. Once parsing succeeds, a request naming a known
  tool is relabeled with that tool's REST method and path. Other protocol
  requests remain recorded as `/mcp`.
  """

  alias PortalAPI.MCP.Tool
  alias PortalAPI.MCP.Tools
  alias PortalAPI.Plugs.RequestLog

  def init(opts), do: opts

  def call(conn, _opts) do
    relabel(conn)
  end

  defp relabel(
         %{body_params: %{"method" => "tools/call", "params" => %{"name" => name} = params}} =
           conn
       )
       when is_binary(name) do
    case Tools.fetch(name) do
      {:ok, tool} -> as_rest_request(conn, tool, params["arguments"])
      :error -> conn
    end
  end

  defp relabel(conn), do: conn

  defp as_rest_request(conn, %Tool{} = tool, arguments) do
    method = tool.method |> to_string() |> String.upcase()
    RequestLog.update_method_and_path(conn, method, interpolate_path(tool, arguments))
  end

  defp interpolate_path(%Tool{} = tool, arguments) when is_map(arguments) do
    Enum.reduce(tool.path_params, tool.path_template, fn name, path ->
      case Map.fetch(arguments, name) do
        {:ok, value} when is_binary(value) or is_number(value) or is_boolean(value) ->
          String.replace(path, "{#{name}}", value |> to_string() |> URI.encode_www_form())

        _other ->
          path
      end
    end)
  end

  defp interpolate_path(%Tool{} = tool, _arguments), do: tool.path_template
end
