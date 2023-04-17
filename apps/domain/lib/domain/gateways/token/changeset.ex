defmodule Domain.Gateways.Token.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Gateways

  def create_changeset(%Accounts.Account{} = account) do
    %Gateways.Token{}
    |> change()
    |> put_change(:account_id, account.id)
    |> put_change(:value, Domain.Crypto.rand_string())
    |> put_hash(:value, to: :hash)
    |> assoc_constraint(:group)
    |> check_constraint(:hash, name: :hash_not_null, message: "can't be blank")
  end

  def use_changeset(%Gateways.Token{} = token) do
    # TODO: While we don't have token rotation implemented, the tokens are all multi-use
    # delete_changeset(token)

    token
    |> change()
  end

  def delete_changeset(%Gateways.Token{} = token) do
    token
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
    |> put_change(:hash, nil)
    |> check_constraint(:hash, name: :hash_not_null, message: "must be blank")
  end
end
