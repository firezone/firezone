defmodule PortalAPI.OpenAPIController do
  use PortalAPI, :controller

  def index(conn, _params) do
    conn
    |> put_status(:permanent_redirect)
    |> redirect(to: ~p"/openapi.json")
  end
end
