defmodule Web.HealthController do
  use Web, :controller

  def healthz(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{status: "ok"}))
  end
end
