defmodule Web.FallbackController do
  use Web, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_layout(html: {Web.Layouts, :root})
    |> put_view(Web.ErrorHTML)
    |> render("404.html")
  end
end
