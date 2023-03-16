defmodule FzHttp.UsersFixtures do
  alias FzHttp.Repo
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

  def user(attrs \\ %{}) do
    attrs = user_attrs(attrs)
    {role, attrs} = Map.pop(attrs, :role, :admin)
    {:ok, user} = Users.create_user(attrs, role)
    user
  end

  def update(user, updates) do
    user
    |> Ecto.Changeset.change(Map.new(updates))
    |> Repo.update!()
  end

  def disable(user) do
    update(user, %{disabled_at: DateTime.utc_now()})
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
