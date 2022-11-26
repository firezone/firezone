defmodule FzHttp.Configurations.RevokedToken do
  @moduledoc """
  Embedded Schema for storing revoked API tokens.

  In general, it's assumed that most JWTs will never be revoked,
  and instead become invalid by expiring. Due to this, we store
  them in this memory-cache-backed configuration store to avoid
  a DB hit on each request, as is the case with most stateful JWT
  approaches.

  We can then sweep the revoked token list periodically based on its
  expiration, some retention policy, or when the admin decides to.
  """

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :token, :string
    field :revoked_at, :utc_datetime_usec
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token,
      :revoked_at
    ])
    |> validate_required([
      :token,
      :revoked_at
    ])
  end
end
