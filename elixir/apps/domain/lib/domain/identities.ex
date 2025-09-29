defmodule Domain.Identities do
  alias Domain.{
    Accounts,
    Actors,
    Auth,
    Repo
  }

  def fetch_identity_by_idp_fields(%Accounts.Account{} = account, issuer, idp_id) do
    Auth.Identity.Query.all()
    |> Auth.Identity.Query.by_account_id(account.id)
    |> Auth.Identity.Query.by_issuer(issuer)
    |> Auth.Identity.Query.by_idp_id(idp_id)
    |> Repo.fetch(Auth.Identity.Query, preload: [:actor, :account])
  end

  def create_identity(%Actors.Actor{} = actor, attrs) do
    Auth.Identity.Changeset.create(actor, attrs)
    |> Repo.insert()
  end
end
