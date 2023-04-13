defmodule Domain.Relays.Token.Changeset do
  use Domain, :changeset
  alias Domain.Relays

  def create_changeset do
    %Relays.Token{}
    |> change()
    |> put_change(:value, Domain.Crypto.rand_string())
    |> put_hash(:value, to: :hash)
    |> assoc_constraint(:group)
    |> check_constraint(:hash, name: :hash_not_null, message: "can't be blank")
  end

  def use_changeset(%Relays.Token{} = token) do
    # TODO: While we don't have token rotation implemented, the tokens are all multi-use
    # delete_changeset(token)

    token
    |> change()
  end

  def delete_changeset(%Relays.Token{} = token) do
    token
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
    |> put_change(:hash, nil)
    |> check_constraint(:hash, name: :hash_not_null, message: "must be blank")
  end
end
