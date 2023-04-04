defmodule Domain.ApiTokens.ApiToken do
  use Domain, :schema

  schema "api_tokens" do
    field :expires_at, :utc_datetime_usec

    # Developer-friendly way to set expires_at
    field :expires_in, :integer, virtual: true, default: 30

    belongs_to :user, Domain.Users.User

    timestamps(updated_at: false)
  end
end
