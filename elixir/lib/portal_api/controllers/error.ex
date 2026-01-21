defmodule PortalAPI.Error do
  @moduledoc """
  Centralized error handling for API controllers.

  Provides explicit `handle/2` functions for all error cases,
  avoiding action_fallback macros which can break stack traces.
  """
  import Plug.Conn
  import Phoenix.Controller

  require Logger

  @spec handle(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def handle(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"404")
  end

  def handle(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"401")
  end

  def handle(conn, {:error, :bad_request}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"400")
  end

  def handle(conn, {:error, :bad_request, reason: reason}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, reason: reason)
  end

  def handle(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"403")
  end

  def handle(conn, {:error, :forbidden, reason: reason}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, reason: reason)
  end

  def handle(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ChangesetJSON)
    |> render(:error, status: 422, changeset: changeset)
  end

  def handle(conn, error) do
    Logger.error("Unhandled API error", error: inspect(error))

    conn
    |> put_status(:internal_server_error)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"500")
  end
end
