defmodule FzHttp.UsersFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.Users` context.
  """

  alias FzHttp.{Repo, Users, Users.User}

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
              role: :admin,
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
