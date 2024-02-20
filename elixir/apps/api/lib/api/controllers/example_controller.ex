defmodule API.ExampleController do
  use API, :controller

  def echo(conn, params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(params))
  end
end
