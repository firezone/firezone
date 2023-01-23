defmodule FzHttp.ApiTokens.ApiToken do
  use FzHttp, :schema

  schema "api_tokens" do
    field :expires_at, :utc_datetime_usec

    # Developer-friendly way to set expires_at
    field :expires_in, :integer, virtual: true, default: 30

    belongs_to :user, FzHttp.Users.User

    timestamps(updated_at: false)
  end
end
