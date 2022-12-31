defmodule FzHttpWeb.JSON.UserController do
  use FzHttpWeb, :controller

  alias FzHttp.Users
  alias FzHttp.Users.User

  action_fallback FzHttpWeb.JSON.FallbackController

  def index(conn, _params) do
    users = Users.list_users()
    render(conn, "index.json", users: users)
  end

  def create(conn, %{"user" => user_params}) do
    with {:ok, %User{} = user} <- Users.create_user(user_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/users/#{user}")
      |> render("show.json", user: user)
    end
  end

  def show(conn, %{"id" => id_or_email}) do
    user = get_user_by_id_or_email(id_or_email)
    render(conn, "show.json", user: user)
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    user = Users.get_user!(id)

    with {:ok, %User{} = user} <- Users.admin_update_user(user, user_params) do
      render(conn, "show.json", user: user)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = Users.get_user!(id)

    with {:ok, %User{}} <- Users.delete_user(user) do
      send_resp(conn, :no_content, "")
    end
  end

  defp get_user_by_id_or_email(id_or_email) do
    if String.contains?(id_or_email, "@") do
      Users.get_by_email!(id_or_email)
    else
      Users.get_user!(id_or_email)
    end
  end
end
