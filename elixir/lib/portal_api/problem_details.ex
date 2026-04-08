defmodule PortalAPI.ProblemDetails do
  @moduledoc """
  Builds RFC 9457 (Problem Details for HTTP APIs) responses.

  See: https://www.rfc-editor.org/rfc/rfc9457
  """
  import Plug.Conn

  @content_type "application/problem+json"

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
end
