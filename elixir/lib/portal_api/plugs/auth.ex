defmodule PortalAPI.Plugs.Auth do
  @moduledoc """
  Authenticates a REST request from its bearer token.

  A request carrying an already-authenticated subject under
  `#{inspect(__MODULE__)}.subject_key/0` skips the token lookup. That is set
  only by `PortalAPI.MCP.Dispatch`, which re-enters the router with a subject it
  authenticated a moment earlier. Connection private state cannot be set by a
  request, so this cannot be reached from outside the application, and without
  it an MCP tool call would be re-authenticated against the wrong credential
  type and fail.
  """

  import Plug.Conn

  @subject_key :portal_api_authenticated_subject

  @doc "Private key carrying a subject that was authenticated upstream."
  def subject_key, do: @subject_key

  def init(opts), do: Keyword.get(opts, :context_type, :api_client)

  def call(%Plug.Conn{private: %{@subject_key => subject}} = conn, _context_type) do
    assign(conn, :subject, subject)
  end

  def call(conn, context_type) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip

    context =
      Portal.Authentication.Context.build(remote_ip, user_agent, conn.req_headers, context_type)

    with ["Bearer " <> encoded_token] <- get_req_header(conn, "authorization"),
         {:ok, subject} <- Portal.Authentication.authenticate(encoded_token, context) do
      assign(conn, :subject, subject)
    else
      _ ->
        PortalAPI.ProblemDetails.send(
          conn,
          401,
          "Authentication credentials were missing or invalid."
        )
    end
  end
end
