defmodule Domain.Gateways.Token.Changeset do
  use Domain, :changeset
  alias Domain.Gateways

  def create_changeset do
    %Gateways.Token{}
    |> change()
    |> put_change(:value, Domain.Crypto.rand_string())
    |> put_hash(:value, to: :hash)
    |> assoc_constraint(:group)
    |> check_constraint(:hash, name: :hash_not_null, message: "can't be blank")
  end

  def use_changeset(%Gateways.Token{} = token) do
    delete_changeset(token)
  end

  def delete_changeset(%Gateways.Token{} = token) do
    token
    |> change()
    |> put_change(:deleted_at, DateTime.utc_now())
    |> put_change(:hash, nil)
    |> check_constraint(:hash, name: :hash_not_null, message: "must be blank")
  end
end
