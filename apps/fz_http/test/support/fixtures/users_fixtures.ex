defmodule FzHttp.UsersFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.Users` context.
  """

  alias FzHttp.{Repo, Users, Users.User}

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
    email = attrs[:email] || "test-#{counter()}@test"

    case Repo.get_by(User, email: email) do
      nil ->
        {:ok, user} =
          Users.create_user(
            %{
              email: email,
              password: "password1234",
              password_confirmation: "password1234"
            },
            Enum.into(attrs, %{role: :admin})
          )

        user

      %User{} = user ->
        user
    end
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
