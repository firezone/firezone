defmodule Portal.Changes.Hooks.Actors do
  @behaviour Portal.Changes.Hooks
  alias __MODULE__.Database

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
    Database.delete_client_tokens_for_actor(account_id, actor_id)
    Database.delete_portal_sessions_for_actor(account_id, actor_id)

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
    Database.delete_portal_sessions_for_actor(account_id, actor_id)

    :ok
  end

  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  # Side effects are handled by the cascade delete hooks
  def on_delete(_lsn, _old_data), do: :ok

  defmodule Database do
    alias Portal.ClientToken
    alias Portal.PortalSession
    alias Portal.Repo
    import Ecto.Query

    def delete_client_tokens_for_actor(account_id, actor_id) do
      from(c in ClientToken,
        where: c.account_id == ^account_id and c.actor_id == ^actor_id
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()
    end

    def delete_portal_sessions_for_actor(account_id, actor_id) do
      from(p in PortalSession,
        where: p.account_id == ^account_id and p.actor_id == ^actor_id
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()
    end
  end
end
