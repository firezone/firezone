defmodule Domain.Changes.Hooks.AuthProviders do
  @behaviour Domain.Changes.Hooks
  alias __MODULE__.DB

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(_lsn, old_data, %{"account_id" => account_id, "id" => provider_id} = data) do
    if breaking_change?(old_data, data) do
      DB.delete_client_tokens_for_provider(account_id, provider_id)
      DB.delete_portal_sessions_for_provider(account_id, provider_id)
    end

    :ok
  end

  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(_lsn, _old_data), do: :ok

  defmodule DB do
    import Ecto.Query
    alias Domain.ClientToken
    alias Domain.PortalSession
    alias Domain.Safe

    # Delete all GUI client tokens for a provider and disconnect their sockets
    # Service Account tokens do not have an auth provider set and will not be affected
    def delete_client_tokens_for_provider(account_id, provider_id) do
      # The ClientTokens hook will handle disconnecting sockets
      from(c in ClientToken,
        where: c.account_id == ^account_id and c.auth_provider_id == ^provider_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_portal_sessions_for_provider(account_id, provider_id) do
      # The PortalSessions hook will handle disconnecting sockets
      from(p in PortalSession,
        where: p.account_id == ^account_id and p.auth_provider_id == ^provider_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end

  defp breaking_change?(old_data, data) do
    old_data["is_disabled"] != data["is_disabled"] or
      old_data["client_session_lifetime_secs"] != data["client_session_lifetime_secs"] or
      old_data["portal_session_lifetime_secs"] != data["portal_session_lifetime_secs"] or
      old_data["context"] != data["context"] or
      old_data["issuer"] != data["issuer"] or
      old_data["client_id"] != data["client_id"] or
      old_data["client_secret"] != data["client_secret"] or
      old_data["okta_domain"] != data["okta_domain"] or
      old_data["discovery_document_uri"] != data["discovery_document_uri"]
  end
end
