defmodule FzHttp.ApiTokens.ApiToken do
  @moduledoc """
  Stores API Token metadata to check for revocation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FzHttp.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_tokens" do
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:revoked_at])
  end
end
