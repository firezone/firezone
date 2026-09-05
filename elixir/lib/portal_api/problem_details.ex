defmodule PortalAPI.ProblemDetails do
  @moduledoc """
  Builds RFC 9457 (Problem Details for HTTP APIs) responses.

  See: https://www.rfc-editor.org/rfc/rfc9457
  """
  import Plug.Conn

  @content_type "application/problem+json"

  @doc """
  Sends HTTP 429 with the same retry delay in the header and response body.

  MCP transports may expose only the error body to their consumers, so include
  the delay in both human-readable detail and a numeric extension in seconds.
  """
  @spec rate_limited(Plug.Conn.t(), non_neg_integer()) :: Plug.Conn.t()
  def rate_limited(conn, retry_after_ms) do
    retry_after = max(ceil(retry_after_ms / 1000), 1)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> send(429, "Rate limit exceeded. Retry after #{retry_after} seconds.", %{
      retry_after_seconds: retry_after
    })
  end

  @doc """
  Sends an RFC 9457 problem details JSON response.

  `status` is an integer HTTP status code.
  `detail` is a human-readable explanation specific to this occurrence.
  `extensions` is an optional map of extension members (e.g. validation_errors).
  """
  # sobelow_skip ["XSS.SendResp"]
  @spec send(Plug.Conn.t(), integer(), String.t(), map()) :: Plug.Conn.t()
  def send(conn, status, detail, extensions \\ %{}) do
    body =
      %{
        type: "about:blank",
        title: Plug.Conn.Status.reason_phrase(status),
        status: status,
        detail: detail
      }
      |> Map.merge(extensions)

    conn
    |> put_resp_content_type(@content_type)
    |> Plug.Conn.send_resp(status, Phoenix.json_library().encode_to_iodata!(body))
    |> halt()
  end

  @doc """
  Sends an RFC 9457 problem details JSON response carrying a machine-readable `code`.

  `code` is an atom naming the failure reason. It is emitted as a top-level `code`
  extension member holding its snake_case string form, so clients can branch on the
  reason instead of parsing `detail` or guessing from `status`. Several reasons map
  onto the same status code, so `status` alone cannot discriminate between them.
  """
  @spec send_with_code(Plug.Conn.t(), integer(), atom(), String.t(), map()) :: Plug.Conn.t()
  def send_with_code(conn, status, code, detail, extensions \\ %{}) when is_atom(code) do
    send(conn, status, detail, Map.put(extensions, :code, Atom.to_string(code)))
  end
end
