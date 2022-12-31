defmodule FzHttpWeb.JSON.UserView do
  @moduledoc """
  Handles JSON rendering of User records.
  """
  use FzHttpWeb, :view

  def render("index.json", %{users: users}) do
    %{data: render_many(users, __MODULE__, "user.json")}
  end

  def render("show.json", %{user: user}) do
    %{data: render_one(user, __MODULE__, "user.json")}
  end

  @keys_to_render ~w[
    id
    role
    email
    last_signed_in_at
    last_signed_in_method
    disabled_at
    inserted_at
    updated_at
  ]a
  def render("user.json", %{user: user}) do
    Map.take(user, @keys_to_render)
  end
end
