defmodule FzHttp.Fixtures do
  @moduledoc """
  Convenience helpers for inserting records
  """
  alias FzHttp.{Devices, Repo, Rules, Sessions, Users, Users.User}

  # return user specified by email, or generate a new otherwise
  def user(attrs \\ %{}) do
    email = Map.get(attrs, :email, "test-#{counter()}@test")

    case Repo.get_by(User, email: email) do
      nil ->
        {:ok, user} =
          %{email: email, password: "testtest", password_confirmation: "testtest"}
          |> Map.merge(attrs)
          |> Users.create_user()

        user

      %User{} = user ->
        user
    end
  end

  def device(attrs \\ %{}) do
    # don't create a user if user_id is passed
    user_id = Map.get_lazy(attrs, :user_id, fn -> user().id end)

    default_attrs = %{
      user_id: user_id,
      public_key: "test-pubkey",
      name: "factory",
      private_key: "test-privkey",
      server_public_key: "test-server-pubkey"
    }

    {:ok, device} = Devices.create_device(Map.merge(default_attrs, attrs))
    device
  end

  def rule4(attrs \\ %{}) do
    rule(attrs)
  end

  def rule6(attrs \\ %{}) do
    rule(Map.merge(attrs, %{destination: "::/0"}))
  end

  def rule(attrs \\ %{}) do
    default_attrs = %{
      destination: "10.10.10.0/24"
    }

    {:ok, rule} = Rules.create_rule(Map.merge(default_attrs, attrs))
    rule
  end

  def session(_attrs \\ %{}) do
    email = user().email
    record = Sessions.get_session!(email: email)
    create_params = %{email: email, password: "testtest"}
    {:ok, session} = Sessions.create_session(record, create_params)
    session
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
