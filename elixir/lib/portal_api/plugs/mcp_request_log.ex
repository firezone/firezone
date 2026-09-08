defmodule PortalAPI.Plugs.MCPRequestLog do
  @moduledoc """
  Records tool attempts separately from REST dispatch and its outcome.

  The request retains POST /mcp as its method/path. Dispatch is recorded before
  execution; if execution raises or the process dies, its outcome remains
  unknown rather than successful. Arguments, bodies and secrets are not stored.
  """

  alias PortalAPI.Plugs.RequestLog

  def identify(conn, "tools/call", %{"name" => name}) when is_binary(name) do
    RequestLog.update_mcp(conn, %{"tool_name" => String.slice(name, 0, 128)})
  end

  def identify(conn, _method, _params), do: conn

  def dispatched(conn, inner) do
    RequestLog.update_mcp(conn, %{
      "outcome" => "dispatched",
      "method" => inner.method,
      "path" => inner.request_path
    })
  end

  def completed(conn, status) do
    RequestLog.update_mcp(conn, %{
      "outcome" => if(status in 200..299, do: "succeeded", else: "failed"),
      "rest_status" => status
    })
  end

  # Exception rendering can carry an older conn than the last persisted
  # checkpoint. Never overwrite a dispatched operation with that stale state.
  def finalize(%{status: status} = conn) when status >= 500, do: conn

  def finalize(conn) do
    log = conn.assigns.api_request_log

    outcome =
      case log.mcp["outcome"] do
        "received" ->
          cond do
            conn.status == 202 -> "ignored"
            is_binary(log.mcp["tool_name"]) -> "rejected"
            conn.status in 200..299 -> "protocol_response"
            true -> "rejected"
          end

        outcome ->
          outcome
      end

    RequestLog.update_mcp(conn, %{"outcome" => outcome, "http_status" => conn.status})
  end
end
