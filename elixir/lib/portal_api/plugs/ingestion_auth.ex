defmodule PortalAPI.Plugs.IngestionAuth do
  import Plug.Conn
  alias Portal.Authentication
  alias PortalAPI.ProblemDetails

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> encoded_token] <- get_req_header(conn, "authorization"),
         {:ok, token_type, account, token_id, actor} <-
           Authentication.authenticate_ingestion(encoded_token, conn) do
      conn
      |> assign(:account, account)
      |> assign(:token_type, token_type)
      |> assign(:token_id, token_id)
      # The authenticated actor for client tokens; nil for gateway tokens,
      # which authenticate a site rather than an actor.
      |> assign(:actor, actor)
    else
      _ ->
        ProblemDetails.send(conn, 401, "Missing or invalid authorization token")
    end
  end
end
