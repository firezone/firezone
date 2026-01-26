defmodule Portal.Changes.Hooks.AuthProviders do
  @behaviour Portal.Changes.Hooks
  alias __MODULE__.Database

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true

  def on_update(
        _lsn,
        %{"is_disabled" => false},
        %{"is_disabled" => true, "account_id" => account_id, "id" => provider_id}
      ) do
    Database.delete_client_tokens_for_provider(account_id, provider_id)
    Database.delete_portal_sessions_for_provider(account_id, provider_id)

    :ok
  end

  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(_lsn, _old_data), do: :ok

  defmodule Database do
    import Ecto.Query
    alias Portal.ClientToken
    alias Portal.PortalSession
    alias Portal.Repo

    # Delete all GUI client tokens for a provider and disconnect their sockets
    # Service Account tokens do not have an auth provider set and will not be affected
    def delete_client_tokens_for_provider(account_id, provider_id) do
      # The ClientTokens hook will handle disconnecting sockets
      from(c in ClientToken,
        where: c.account_id == ^account_id and c.auth_provider_id == ^provider_id
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()
    end

    def delete_portal_sessions_for_provider(account_id, provider_id) do
      # The PortalSessions hook will handle disconnecting sockets
      from(p in PortalSession,
        where: p.account_id == ^account_id and p.auth_provider_id == ^provider_id
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()
    end
  end
end
