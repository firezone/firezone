defmodule FzHttp.UsersFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.Users` context.
  """
  alias FzHttp.Users

  def user_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: "test-#{counter()}@test",
      password: "password1234",
      password_confirmation: "password1234"
    })
  end

  def create_user_with_role(attrs \\ %{}, role) do
    attrs
    |> Enum.into(%{role: role})
    |> user()
  end

  def create_user(attrs \\ %{}) do
    user(attrs)
  end

  @doc """
  Generate a user specified by email, or generate a new otherwise.
  """
  def user(attrs \\ %{}) do
    attrs = user_attrs(attrs)
    {role, attrs} = Map.pop(attrs, :role, :admin)
    {:ok, user} = Users.create_user(attrs, role)
    user
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
