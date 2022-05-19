defmodule FzHttp.OIDC do
  @moduledoc """
  The OIDC context.
  """

  import Ecto.Query, warn: false

  alias FzHttp.{OIDC.Connection, Repo}

  def get_connection!(site_id, user_id, provider) do
    Repo.get_by!(Connection, site_id: site_id, user_id: user_id, provider: provider)
  end

  def get_connection(site_id, user_id, provider) do
    Repo.get_by(Connection, site_id: site_id, user_id: user_id, provider: provider)
  end

  def create_connection(site_id, user_id, provider, refresh_token) do
    %Connection{site_id: site_id, user_id: user_id}
    |> Connection.changeset(%{provider: provider, refresh_token: refresh_token})
    |> Repo.insert(
      conflict_target: [:site_id, :user_id, :provider],
      on_conflict: {:replace, [:refresh_token]}
    )
  end

  def update_connection(%Connection{} = connection, attrs) do
    connection
    |> Connection.changeset(attrs)
    |> Repo.update()
  end
end
