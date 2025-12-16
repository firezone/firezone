defmodule Domain.Changes.Hooks.AuthProviders do
  @behaviour Domain.Changes.Hooks
  alias __MODULE__.DB

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(
        _lsn,
        %{"is_disabled" => false, "id" => provider_id},
        %{"is_disabled" => true}
      ) do
    DB.delete_tokens_for_provider(provider_id)

    :ok
  end

  def on_update(
        _lsn,
        %{
          "client_session_lifetime_secs" => old_client_lifetime,
          "portal_session_lifetime_secs" => old_portal_lifetime
        },
        %{
          "client_session_lifetime_secs" => new_client_lifetime,
          "portal_session_lifetime_secs" => new_portal_lifetime,
          "id" => provider_id
        }
      )
      when old_client_lifetime != new_client_lifetime or
             old_portal_lifetime != new_portal_lifetime do
    DB.delete_tokens_for_provider(provider_id)

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
    alias Domain.Safe

    # Delete all tokens for a provider and disconnect their sockets
    def delete_tokens_for_provider(provider_id) do
      # Query and delete all tokens for this provider
      # The Tokens hook will handle disconnecting sockets
      from(t in ClientToken,
        where: t.auth_provider_id == ^provider_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
