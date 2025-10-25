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
    |> Auth.Identity.Query.not_disabled()
    |> Repo.fetch(Auth.Identity.Query, preload: [:actor, :account])
  end

  def upsert_identity_by_idp_fields(
        %Accounts.Account{} = account,
        email,
        email_verified,
        issuer,
        idp_id,
        profile_attrs \\ %{}
      ) do
    attrs =
      profile_attrs
      |> Map.put("account_id", account.id)
      |> Map.put("issuer", issuer)
      |> Map.put("idp_id", idp_id)

    with %{valid?: true} <- Auth.Identity.Changeset.upsert(attrs) do
      Auth.Identity.Query.upsert_by_idp_fields(
        account.id,
        email,
        email_verified,
        issuer,
        idp_id,
        profile_attrs
      )
    else
      changeset -> {:error, changeset}
    end
  end

  def create_identity(%Actors.Actor{} = actor, attrs) do
    Auth.Identity.Changeset.create(actor, attrs)
    |> Repo.insert()
  end
end
