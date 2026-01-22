defmodule PortalWeb.Error do
  @moduledoc """
  Centralized error handling for Web controllers.

  Provides explicit `handle/2` functions for all error cases,
  avoiding action_fallback macros which can break stack traces.
  """
  import Plug.Conn
  import Phoenix.Controller

  @spec handle(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def handle(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_layout(html: {PortalWeb.Layouts, :root})
    |> put_view(PortalWeb.ErrorHTML)
    |> render("404.html")
  end

  def handle(conn, {:error, :invalid_provider}) do
    conn
    |> put_status(:not_found)
    |> put_layout(html: {PortalWeb.Layouts, :root})
    |> put_view(PortalWeb.ErrorHTML)
    |> render("404.html")
  end

  def handle(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_layout(html: {PortalWeb.Layouts, :root})
    |> put_view(PortalWeb.ErrorHTML)
    |> render("401.html")
  end

  def handle(conn, error) do
    require Logger
    Logger.error("Unhandled Web error", error: inspect(error))

    conn
    |> put_status(:internal_server_error)
    |> put_layout(html: {PortalWeb.Layouts, :root})
    |> put_view(PortalWeb.ErrorHTML)
    |> render("500.html")
  end
end
