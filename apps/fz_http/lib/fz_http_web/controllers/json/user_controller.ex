defmodule FzHttpWeb.JSON.UserController do
  @moduledoc api_doc: [title: "Users", sidebar_position: 2, toc_max_heading_level: 4]
  @moduledoc """
  This endpoint allows you to provision Users.

  ## Auto-Create Users from OpenID or SAML providers

  You can set Configuration option `auto_create_users` to `true` to automatically create users
  from OpenID or SAML providers. Use it with care as anyone with access to the provider will be
  able to log-in to Firezone.

  If `auto_create_users` is `false`, then you need to provision users with `password` attribute,
  otherwise they will have no means to log in.
  """
  use FzHttpWeb, :controller
  alias FzHttp.Users
  alias FzHttp.Users.User

  action_fallback(FzHttpWeb.JSON.FallbackController)

  @doc api_doc: [action: "List All Users"]
  def index(conn, _params) do
    users = Users.list_users()
    render(conn, "index.json", users: users)
  end

  @doc """
  Allows to create a new User.

  This endpoint is useful in two cases:

    1. When "Password Authentication" is enabled (which is discouraged) it allows to pre-provision users with their passwords;
    2. When "Auto-Create Users" is disabled it allows to pre-provision users with their emails (there is no need to set a password for them),
    effectively whitelisting who can login using OpenID or SAML provider.

  If "Auto-Create Users" is enabled there is no need to pre-create users, they will be created automatically
  when they log in for the first time using OpenID or SAML provider.

  #### User Attributes

  | Attribute | Type | Required | Description |
  | --------- | ---- | -------- | ----------- |
  | `role` | `admin` or `unprivileged` (default) | No | User role. |
  | `email` | `string` | Yes | Email which will be used to identify the user. |
  | `password` | `string` | No | A password that can be used for login-password authentication. |
  | `password_confirmation` | `string` | -> | Is required when the `password` is set. |
  """
  @doc api_doc: [action: "Create a User"]
  def create(conn, %{"user" => %{"role" => "admin"} = user_params}) do
    with {:ok, %User{} = user} <- Users.create_admin_user(user_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/users/#{user}")
      |> render("show.json", user: user)
    end
  end

  def create(conn, %{"user" => user_params}) do
    with {:ok, %User{} = user} <- Users.create_unprivileged_user(user_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/users/#{user}")
      |> render("show.json", user: user)
    end
  end

  @doc api_doc: [summary: "Get User by ID or Email"]
  def show(conn, %{"id" => id_or_email}) do
    user = get_user_by_id_or_email(id_or_email)
    render(conn, "show.json", user: user)
  end

  @doc """
  For details please see [Create a User](#create-a-user-post-v0users) section.
  """
  @doc api_doc: [action: "Update a User"]
  def update(conn, %{"id" => id_or_email, "user" => user_params}) do
    user = get_user_by_id_or_email(id_or_email)

    with {:ok, %User{} = user} <- Users.admin_update_user(user, user_params) do
      render(conn, "show.json", user: user)
    end
  end

  @doc api_doc: [summary: "Delete a User"]
  def delete(conn, %{"id" => id_or_email}) do
    user = get_user_by_id_or_email(id_or_email)

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
