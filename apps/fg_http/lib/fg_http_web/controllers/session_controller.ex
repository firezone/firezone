defmodule FgHttpWeb.SessionController do
  @moduledoc """
  Implements the CRUD for a Session
  """

  alias FgHttp.{Sessions, Users, Users.Session}
  use FgHttpWeb, :controller

  # GET /sign_in/:token
  def create(conn, %{"token" => token}) do
    resp = Users.consume_sign_in_token(token)

    case resp do
      {:ok, user} ->
        conn
        |> clear_session()
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Signed in successfully.")
        |> redirect(to: Routes.device_path(conn, :index))

      {:error, error_msg} ->
        conn
        |> put_flash(:error, error_msg)
        |> redirect(to: "/")
    end
  end

  # DELETE /sign_out
  def delete(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: "/")
  end
end
