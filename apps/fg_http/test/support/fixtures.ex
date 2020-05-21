defmodule FgHttp.Fixtures do
  @moduledoc """
  Convenience helpers for inserting records
  """
  alias FgHttp.{Devices, Repo, Sessions, Users, Users.User}

  def fixture(:user) do
    case Repo.get_by(User, email: "test") do
      nil ->
        attrs = %{email: "test", password: "test", password_confirmation: "test"}
        {:ok, user} = Users.create_user(attrs)
        user

      %User{} = user ->
        user
    end
  end

  def fixture(:device) do
    attrs = %{public_key: "foobar", ifname: "wg0", name: "factory"}
    {:ok, device} = Devices.create_device(Map.merge(%{user_id: fixture(:user).id}, attrs))
    device
  end

  def fixture(:session, attrs \\ %{}) do
    {:ok, _session} = Sessions.create_session(attrs)
  end
end
