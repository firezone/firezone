defmodule FzHttp.UsersFixtures do
  alias FzHttp.Repo
  alias FzHttp.Users
  alias FzHttp.SubjectFixtures

  def user_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: "test-#{counter()}@test",
      password: "password1234",
      password_confirmation: "password1234"
    })
  end

  def create_user_with_role(role, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        SubjectFixtures.new()
        |> SubjectFixtures.set_permissions([
          Users.Authorizer.manage_users_permission()
        ])
      end)

    attrs = user_attrs(attrs)

    {:ok, user} = Users.create_user(role, attrs, subject)
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
