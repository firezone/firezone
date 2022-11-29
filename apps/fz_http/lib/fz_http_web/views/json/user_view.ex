defmodule FzHttpWeb.JSON.UserView do
  @moduledoc """
  Helper functions for User views.
  """
  use FzHttpWeb, :view

  @keys_to_render ~w[
    id
    uuid
    role
    email
    last_signed_in_at
    last_signed_in_method
    disabled_at
    inserted_at
    updated_at
  ]a

  def render("index.json", %{users: users}) do
    %{data: render_many(users, __MODULE__, "user.json")}
  end

  def render("show.json", %{user: user}) do
    %{data: render_one(user, __MODULE__, "user.json")}
  end

  def render("user.json", %{user: user}) do
    Map.take(user, @keys_to_render)
  end
end
