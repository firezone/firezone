defmodule Domain.Changes.Hooks.AuthProviders do
  @behaviour Domain.Changes.Hooks
  alias __MODULE__.DB

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(
        _lsn,
        %{"is_disabled" => false, "id" => provider_id, "account_id" => account_id},
        %{"is_disabled" => true}
      ) do
    DB.delete_client_tokens_for_provider(account_id, provider_id)
    DB.delete_portal_sessions_for_provider(account_id, provider_id)

    :ok
  end

  def on_update(
        _lsn,
        %{
          "client_session_lifetime_secs" => old_client_lifetime,
          "portal_session_lifetime_secs" => old_portal_lifetime,
          "account_id" => account_id
        },
        %{
          "client_session_lifetime_secs" => new_client_lifetime,
          "portal_session_lifetime_secs" => new_portal_lifetime,
          "id" => provider_id
        }
      )
      when old_client_lifetime != new_client_lifetime or
             old_portal_lifetime != new_portal_lifetime do
    DB.delete_client_tokens_for_provider(account_id, provider_id)
    DB.delete_portal_sessions_for_provider(account_id, provider_id)

    :ok
  end

  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(_lsn, _old_data) do
    :ok
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.ClientToken
    alias Domain.PortalSession
    alias Domain.Safe

    # Delete all client tokens for a provider and disconnect their sockets
    def delete_client_tokens_for_provider(account_id, provider_id) do
      # The ClientTokens hook will handle disconnecting sockets
      from(c in ClientToken,
        where: c.account_id == ^account_id and c.auth_provider_id == ^provider_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_portal_sessions_for_provider(account_id, provider_id) do
      # The ClientTokens hook will handle disconnecting sockets
      from(p in PortalSession,
        where: p.account_id == ^account_id and p.auth_provider_id == ^provider_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
