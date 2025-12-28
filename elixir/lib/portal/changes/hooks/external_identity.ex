defmodule Portal.Changes.Hooks.ExternalIdentities do
  @behaviour Portal.Changes.Hooks
  alias __MODULE__.DB

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(_lsn, %{
        "account_id" => account_id,
        "issuer" => issuer,
        "actor_id" => actor_id
      }) do
    DB.delete_client_tokens(account_id, actor_id, issuer)
    DB.delete_portal_sessions(account_id, actor_id, issuer)

    :ok
  end

  defmodule DB do
    alias Portal.ClientToken
    alias Portal.PortalSession
    alias Portal.Safe
    import Ecto.Query

    def delete_client_tokens(account_id, actor_id, issuer) do
      auth_provider_ids = auth_provider_ids_for_issuer(issuer)

      from(c in ClientToken,
        where:
          c.account_id == ^account_id and
            c.actor_id == ^actor_id and
            c.auth_provider_id in subquery(auth_provider_ids)
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_portal_sessions(account_id, actor_id, issuer) do
      auth_provider_ids = auth_provider_ids_for_issuer(issuer)

      from(p in PortalSession,
        where:
          p.account_id == ^account_id and
            p.actor_id == ^actor_id and
            p.auth_provider_id in subquery(auth_provider_ids)
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    defp auth_provider_ids_for_issuer(issuer) do
      from(g in Portal.Google.AuthProvider, where: g.issuer == ^issuer, select: g.id)
      |> union(^from(o in Portal.Okta.AuthProvider, where: o.issuer == ^issuer, select: o.id))
      |> union(^from(e in Portal.Entra.AuthProvider, where: e.issuer == ^issuer, select: e.id))
      |> union(
        ^from(oidc in Portal.OIDC.AuthProvider, where: oidc.issuer == ^issuer, select: oidc.id)
      )
    end
  end
end
