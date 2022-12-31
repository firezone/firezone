defmodule FzHttp.OIDC.Connection do
  @moduledoc """
  OIDC connections
  """
  use FzHttp, :schema
  import Ecto.Changeset

  schema "oidc_connections" do
    field :provider, :string
    field :refresh_response, :map
    field :refresh_token, :string
    field :refreshed_at, :utc_datetime_usec

    belongs_to :user, FzHttp.Users.User

    timestamps()
  end

  @doc false
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:provider, :refresh_token, :refreshed_at, :refresh_response])
    |> validate_required([:provider, :refresh_token])
  end
end
