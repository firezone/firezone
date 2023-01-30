defmodule FzHttpWeb.JSON.UserController do
  @moduledoc api_doc: [title: "Users", sidebar_position: 2, toc_max_heading_level: 4]
  @moduledoc """
  This endpoint allows an administrator to manage Users.

  ## Auto-Create Users from OpenID or SAML providers

  You can set Configuration option `auto_create_users` to `true` to automatically create users
  from OpenID or SAML providers. Use it with care as anyone with access to the provider will be
  able to log-in to Firezone.

  If `auto_create_users` is `false`, then you need to provision users with `password` attribute,
  otherwise they will have no means to log in.

  ## Disabling users

  Even though API returns `disabled_at` attribute, currently, it's not possible to disable users via API,
  since this field is only for internal use by automatic user disabling mechanism on OIDC/SAML errors.
  """
  use FzHttpWeb, :controller
  alias FzHttp.Users

  action_fallback(FzHttpWeb.JSON.FallbackController)

  @doc api_doc: [action: "List all Users"]
  def index(conn, _params) do
    with {:ok, users} <- Users.list_users() do
      render(conn, "index.json", users: users)
    end
  end

  @doc """
  Create a new User.

  This endpoint is useful in two cases:

    1. When [Local Authentication](/authenticate/local-auth/) is enabled (discouraged in
      production deployments), it allows an administrator to provision users with their passwords;
    2. When `auto_create_users` in the associated OpenID or SAML configuration is disabled,
      it allows an administrator to provision users with their emails beforehand, effectively
      whitelisting specific users for authentication.

  If `auto_create_users` is `true` in the associated OpenID or SAML configuration, there is no need
  to provision users; they will be created automatically when they log in for the first time using
  the associated OpenID or SAML provider.

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
    with {:ok, %Users.User{} = user} <- Users.create_admin_user(user_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/users/#{user}")
      |> render("show.json", user: user)
    end
  end

  def create(conn, %{"user" => user_params}) do
    with {:ok, %Users.User{} = user} <- Users.create_unprivileged_user(user_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/users/#{user}")
      |> render("show.json", user: user)
    end
  end

  @doc api_doc: [summary: "Get User by ID or Email"]
  def show(conn, %{"id" => id_or_email}) do
    with {:ok, %Users.User{} = user} <- Users.fetch_user_by_id_or_email(id_or_email) do
      render(conn, "show.json", user: user)
    end
  end

  @doc """
  For details please see [Create a User](#create-a-user-post-v0users) section.
  """
  @doc api_doc: [action: "Update a User"]
  def update(conn, %{"id" => id_or_email, "user" => user_params}) do
    with {:ok, %Users.User{} = user} <- Users.fetch_user_by_id_or_email(id_or_email),
         {:ok, %Users.User{} = user} <- Users.admin_update_user(user, user_params) do
      render(conn, "show.json", user: user)
    end
  end

  @doc api_doc: [summary: "Delete a User"]
  def delete(conn, %{"id" => id_or_email}) do
    with {:ok, %Users.User{} = user} <- Users.fetch_user_by_id_or_email(id_or_email),
         {:ok, %Users.User{}} <- Users.delete_user(user) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(:no_content, "")
    end
  end
end
