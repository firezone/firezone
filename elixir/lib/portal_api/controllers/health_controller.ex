defmodule API.HealthController do
  use API, :controller

  def healthz(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{status: "ok"}))
    |> halt()
  end
end
