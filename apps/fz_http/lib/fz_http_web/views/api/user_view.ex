defmodule FzHttpWeb.API.UserView do
  @moduledoc """
  Helper functions for User views.
  """
  use FzHttpWeb, :view
  alias FzHttpWeb.API.UserView

  def render("index.json", %{users: users}) do
    %{data: render_many(users, UserView, "user.json")}
  end

  def render("show.json", %{user: user}) do
    %{data: render_one(user, UserView, "user.json")}
  end

  def render("user.json", %{user: user}) do
    %{
      id: user.id,
      uuid: user.uuid,
      role: user.role,
      email: user.email,
      last_signed_in_at: user.last_signed_in_at,
      last_signed_in_method: user.last_signed_in_method,
      password_hash: user.password_hash,
      sign_in_token: user.sign_in_token,
      sign_in_token_created_at: user.sign_in_token_created_at,
      disabled_at: user.disabled_at,
      # devices: user.devices,
      # oidc_connections: user.oidc_connections,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
