defmodule PortalAPI.Plugs.IngestionAuth do
  import Plug.Conn
  alias Portal.Authentication
  alias PortalAPI.ProblemDetails

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> encoded_token] <- get_req_header(conn, "authorization"),
         {:ok, _token_type, account, token_id} <-
           Authentication.authenticate_ingestion(encoded_token, conn) do
      conn
      |> assign(:account, account)
      |> assign(:token_id, token_id)
    else
      _ ->
        ProblemDetails.send(conn, 401, "Missing or invalid authorization token")
    end
  end
end
