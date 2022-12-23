defmodule FzHttp.ApiTokens.ApiToken do
  @moduledoc """
  Stores API Token metadata to check for revocation.
  """
  use FzHttp, :schema
  import Ecto.Changeset
  alias FzHttp.Users.User

  @max_per_user 10

  schema "api_tokens" do
    field :expires_at, :utc_datetime_usec

    # User-friendly way to set expires_at
    field :expires_in, :integer, virtual: true, default: 30

    belongs_to :user, User

    timestamps(updated_at: false)
  end

  def changeset(api_token, attrs, opts \\ []) do
    api_token
    |> cast(attrs, ~w[
      user_id
      expires_in
      expires_at
    ]a)
    |> validate_required([:user_id, :expires_in])
    |> validate_number(:expires_in, greater_than_or_equal_to: 1, less_than_or_equal_to: 90)
    |> resolve_expires_at()
    |> validate_required(:expires_at)
    |> assoc_constraint(:user)
    |> maybe_validate_count_per_user(@max_per_user, opts[:count_per_user])
  end

  def max_per_user, do: @max_per_user

  defp resolve_expires_at(changeset) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(get_field(changeset, :expires_in), :day)

    put_change(changeset, :expires_at, expires_at)
  end

  defp maybe_validate_count_per_user(changeset, max, num) when is_integer(num) and num >= max do
    add_error(changeset, :base, "token limit of #{@max_per_user} reached")
  end

  defp maybe_validate_count_per_user(changeset, _, _), do: changeset
end
