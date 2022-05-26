defmodule FzHttp.OIDC do
  @moduledoc """
  The OIDC context.
  """

  import Ecto.Query, warn: false

  alias FzHttp.{OIDC.Connection, Repo, Users.User}

  def list_connections(%User{id: id}) do
    Repo.all(from Connection, where: [user_id: ^id])
  end

  def get_connection!(user_id, provider) do
    Repo.get_by!(Connection, user_id: user_id, provider: provider)
  end

  def get_connection(user_id, provider) do
    Repo.get_by(Connection, user_id: user_id, provider: provider)
  end

  def create_connection(user_id, provider, refresh_token) do
    %Connection{user_id: user_id}
    |> Connection.changeset(%{provider: provider, refresh_token: refresh_token})
    |> Repo.insert(
      conflict_target: [:user_id, :provider],
      on_conflict: {:replace, [:refresh_token]}
    )
  end

  def update_connection(%Connection{} = connection, attrs) do
    connection
    |> Connection.changeset(attrs)
    |> Repo.update()
  end
end
