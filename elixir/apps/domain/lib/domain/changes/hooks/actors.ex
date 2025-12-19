defmodule Domain.Changes.Hooks.Actors do
  @behaviour Domain.Changes.Hooks
  alias __MODULE__.DB

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true

  # Delete api_tokens, client_tokens, and portal_sessions when an actor is disabled
  def on_update(
        _lsn,
        %{
          "disabled_at" => nil,
          "account_id" => account_id,
          "id" => actor_id
        },
        %{"disabled_at" => disabled_at}
      )
      when not is_nil(disabled_at) do
    DB.delete_client_tokens_for_actor(account_id, actor_id)
    DB.delete_portal_sessions_for_actor(account_id, actor_id)

    :ok
  end

  # Delete portal_sessions when an active account_admin_user is changed to account_user
  def on_update(
        _lsn,
        %{
          "disabled_at" => nil,
          "type" => "account_admin_user"
        },
        %{
          "disabled_at" => nil,
          "type" => "account_user",
          "account_id" => account_id,
          "id" => actor_id
        }
      ) do
    DB.delete_portal_sessions_for_actor(account_id, actor_id)

    :ok
  end

  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  # Side effects are handled by the cascade delete hooks
  def on_delete(_lsn, _old_data), do: :ok

  defmodule DB do
    alias Domain.ClientToken
    alias Domain.PortalSession
    alias Domain.Safe
    import Ecto.Query

    def delete_client_tokens_for_actor(account_id, actor_id) do
      from(c in ClientToken,
        where: c.account_id == ^account_id and c.actor_id == ^actor_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_portal_sessions_for_actor(account_id, actor_id) do
      from(p in PortalSession,
        where: p.account_id == ^account_id and p.actor_id == ^actor_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
