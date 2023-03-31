defmodule FzHttp.Auth.OIDC.Connection do
  use FzHttp, :schema

  schema "oidc_connections" do
    field :provider, :string
    field :refresh_response, :map
    field :refresh_token, :string
    field :refreshed_at, :utc_datetime_usec

    belongs_to :user, FzHttp.Users.User

    timestamps()
  end
end
