defmodule FzHttp.Fixtures do
  @moduledoc """
  Convenience helpers for inserting records
  """
  alias FzHttp.{Devices, PasswordResets, Repo, Rules, Sessions, Users, Users.User}

  # return user specified by email, or generate a new otherwise
  def user(attrs \\ %{}) do
    email = Map.get(attrs, :email, "test-#{counter()}@test")

    case Repo.get_by(User, email: email) do
      nil ->
        {:ok, user} =
          %{email: email, password: "test", password_confirmation: "test"}
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
      interface_address4: "10.0.0.1",
      interface_address6: "::1",
      public_key: "test-pubkey",
      name: "factory",
      private_key: "test-privkey",
      preshared_key: "test-psk",
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
    # don't create a device if device_id is passed
    device_id = Map.get_lazy(attrs, :device_id, fn -> device().id end)

    default_attrs = %{
      device_id: device_id,
      destination: "10.10.10.0/24"
    }

    {:ok, rule} = Rules.create_rule(Map.merge(default_attrs, attrs))
    rule
  end

  def session(_attrs \\ %{}) do
    email = user().email
    record = Sessions.get_session!(email: email)
    create_params = %{email: email, password: "test"}
    {:ok, session} = Sessions.create_session(record, create_params)
    session
  end

  def password_reset(attrs \\ %{}) do
    email = user().email

    create_attrs = Map.merge(attrs, %{email: email})

    {:ok, password_reset} =
      PasswordResets.get_password_reset!(email: email)
      |> PasswordResets.create_password_reset(create_attrs)

    password_reset
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
