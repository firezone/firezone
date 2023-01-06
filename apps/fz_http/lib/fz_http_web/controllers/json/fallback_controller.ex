defmodule FzHttpWeb.JSON.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use FzHttpWeb, :controller

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(FzHttpWeb.ErrorView)
    |> render("404.json")
  end

  def call(conn, {:error, :internal_server_error}) do
    conn
    |> put_status(:internal_server_error)
    |> put_view(FzHttpWeb.ErrorView)
    |> render("500.json")
  end

  def call(conn, {:error, %Ecto.Changeset{valid?: false} = changeset}) do
    conn
    |> put_status(422)
    |> put_view(FzHttpWeb.JSON.ChangesetView)
    |> render("error.json", changeset: changeset)
  end
end
