defmodule FzHttp.ApiTokens.ApiToken.Changeset do
  use FzHttp, :changeset
  alias FzHttp.ApiTokens.ApiToken

  @max_per_user 25

  def create_changeset(user, attrs, opts \\ []) do
    changeset(attrs)
    |> put_change(:user_id, user.id)
    |> assoc_constraint(:user)
    |> maybe_validate_count_per_user(@max_per_user, opts[:max])
  end

  def changeset(api_token \\ %ApiToken{}, attrs) do
    api_token
    |> cast(attrs, ~w[
      expires_in
      expires_at
    ]a)
    |> validate_required([:expires_in])
    |> validate_number(:expires_in, greater_than_or_equal_to: 1, less_than_or_equal_to: 90)
    |> resolve_expires_at()
    |> validate_required(:expires_at)
  end

  def max_per_user, do: @max_per_user

  defp resolve_expires_at(changeset) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(get_field(changeset, :expires_in), :day)

    put_change(changeset, :expires_at, expires_at)
  end

  defp maybe_validate_count_per_user(changeset, max, num) when is_integer(num) and num >= max do
    # XXX: This suffers from a race condition because the count happens in a separate transaction.
    # At the moment it's not a big concern. Fixing it would require locking against INSERTs or DELETEs
    # while counts are happening.
    add_error(changeset, :base, "token limit of #{@max_per_user} reached")
  end

  defp maybe_validate_count_per_user(changeset, _, _), do: changeset
end
