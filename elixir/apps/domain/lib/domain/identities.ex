defmodule Domain.Identities do
  alias Domain.{
    Accounts,
    Actors,
    Auth.Identity,
    Repo
  }

  def fetch_identity_by_idp_fields(%Accounts.Account{} = account, issuer, idp_tenant, idp_id) do
    Identity.Query.all()
    |> Identity.Query.by_account_id(account.id)
    |> Identity.Query.by_issuer(issuer)
    |> Identity.Query.by_idp_tenant(idp_tenant)
    |> Identity.Query.by_idp_id(idp_id)
    |> Repo.fetch(Identity.Query, preload: :actor)
  end

  def create_identity(%Actors.Actor{} = actor, attrs) do
    Identity.Changeset.create(actor, attrs)
    |> Repo.insert()
  end
end
