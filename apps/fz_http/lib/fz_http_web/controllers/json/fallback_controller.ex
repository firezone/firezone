defmodule FzHttpWeb.JSON.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use FzHttpWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{valid?: false} = changeset}) do
    conn
    |> put_status(422)
    |> put_view(FzHttpWeb.JSON.ChangesetView)
    |> render("error.json", changeset: changeset)
  end
end
