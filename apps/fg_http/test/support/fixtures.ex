defmodule FgHttp.Fixtures do
  @moduledoc """
  Convenience helpers for inserting records
  """
  alias FgHttp.{Devices, PasswordResets, Repo, Rules, Sessions, Users, Users.User}

  def user(attrs \\ %{}) do
    case Repo.get_by(User, email: "test@test") do
      nil ->
        {:ok, user} =
          %{email: "test@test", password: "test", password_confirmation: "test"}
          |> Map.merge(attrs)
          |> Users.create_user()

        user

      %User{} = user ->
        user
    end
  end

  def device(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{user_id: user().id})
      |> Enum.into(%{
        interface_address: "10.0.0.1",
        public_key: "test-pubkey",
        name: "factory",
        private_key: "test-privkey",
        preshared_key: "test-psk",
        server_public_key: "test-server-pubkey"
      })

    {:ok, device} = Devices.create_device(attrs)
    device
  end

  def rule(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{device_id: device().id})
      |> Enum.into(%{destination: "0.0.0.0/0"})

    {:ok, rule} = Rules.create_rule(attrs)
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
end
