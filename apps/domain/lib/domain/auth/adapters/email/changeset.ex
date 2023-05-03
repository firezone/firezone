defmodule Domain.Auth.Adapters.Email.Changeset do
  use Domain, :changeset

  def sign_in_token_changeset(sign_in_token) do
    types = %{sign_in_token_hash: :string, sign_in_token_created_at: :utc_datetime_usec}

    {%{}, types}
    |> cast(%{}, Map.keys(types))
    |> put_change(:sign_in_token_hash, Domain.Crypto.hash(sign_in_token))
    |> put_change(:sign_in_token_created_at, DateTime.utc_now())
  end
end
