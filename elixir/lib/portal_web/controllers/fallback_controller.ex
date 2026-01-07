defmodule PortalWeb.FallbackController do
  use PortalWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_layout(html: {PortalWeb.Layouts, :root})
    |> put_view(PortalWeb.ErrorHTML)
    |> render("404.html")
  end

  def call(conn, {:error, :invalid_provider}) do
    conn
    |> put_status(:not_found)
    |> put_layout(html: {PortalWeb.Layouts, :root})
    |> put_view(PortalWeb.ErrorHTML)
    |> render("404.html")
  end
end
