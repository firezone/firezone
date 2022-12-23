defmodule FzHttp.ApiTokens.ApiToken do
  @moduledoc """
  Stores API Token metadata to check for revocation.
  """
  use FzHttp, :schema
  import Ecto.Changeset
  alias FzHttp.Users.User

  schema "api_tokens" do
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [
      :user_id,
      :revoked_at
    ])
    |> validate_required(:user_id)
    |> assoc_constraint(:user)
  end
end
