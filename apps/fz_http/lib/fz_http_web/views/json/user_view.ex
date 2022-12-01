defmodule FzHttpWeb.JSON.UserView do
  @moduledoc """
  Helper functions for User views.
  """
  use FzHttpWeb, :view

  def render("index.json", %{users: users}) do
    %{data: render_many(users, __MODULE__, "user.json")}
  end

  def render("show.json", %{user: user}) do
    %{data: render_one(user, __MODULE__, "user.json")}
  end

  def render("user.json", %{user: user}) do
    %{
      id: user.id,
      uuid: user.uuid,
      role: user.role,
      email: user.email,
      last_signed_in_at: user.last_signed_in_at,
      last_signed_in_method: user.last_signed_in_method,
      disabled_at: user.disabled_at,
      # devices: user.devices,
      # oidc_connections: user.oidc_connections,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
