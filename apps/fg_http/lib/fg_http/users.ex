defmodule FgHttp.Users do
  @moduledoc """
  The Users context.
  """

  import Ecto.Query, warn: false
  alias FgHttp.Repo

  alias FgHttp.Users.User

  def get_user!(email: email) do
    Repo.get_by!(User, email: email)
  end

  def get_user!(id), do: Repo.get!(User, id)

  def create_user(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> create_user()
  end

  def create_user(attrs) when is_map(attrs) do
    %User{}
    |> User.create_changeset(attrs)
    |> Repo.insert()
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  def change_user(%User{} = user) do
    User.changeset(user, %{})
  end
end
