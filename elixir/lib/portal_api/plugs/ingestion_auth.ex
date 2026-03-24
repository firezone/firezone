defmodule PortalAPI.Plugs.IngestionAuth do
  import Plug.Conn
  alias Portal.Authentication

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
        conn
        |> put_status(401)
        |> Phoenix.Controller.put_view(json: PortalAPI.ErrorJSON)
        |> Phoenix.Controller.render(:"401")
        |> halt()
    end
  end
end
