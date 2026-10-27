defmodule Portal.Changes.Hooks.Actors do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  alias __MODULE__.Database
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    actor = struct_from_params(Portal.Actor, data)
    change = %Change{lsn: lsn, op: :insert, struct: actor}
    PubSub.Changes.broadcast(actor.account_id, :actors, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    :ok = handle_update_side_effects(old_data, data)

    old_actor = struct_from_params(Portal.Actor, old_data)
    actor = struct_from_params(Portal.Actor, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_actor, struct: actor}
    PubSub.Changes.broadcast(actor.account_id, :actors, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    actor = struct_from_params(Portal.Actor, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: actor}
    PubSub.Changes.broadcast(actor.account_id, :actors, change)
  end

  # Delete client_tokens, portal_sessions, and OAuth grants when an actor is
  # disabled. Re-enabling the actor would otherwise bring them all back.
  defp handle_update_side_effects(
         %{
           "is_disabled" => false,
           "account_id" => account_id,
           "id" => actor_id
         },
         %{"is_disabled" => true}
       ) do
    Database.delete_client_tokens_for_actor(account_id, actor_id)
    Database.delete_portal_sessions_for_actor(account_id, actor_id)
    Database.delete_oauth_grants_for_actor(account_id, actor_id)

    :ok
  end

  # Delete portal_sessions and OAuth grants when an account_admin_user loses
  # the admin role. Only an admin can grant an MCP client access, so the grant
  # and every token issued under it go with the role.
  defp handle_update_side_effects(
         %{"type" => "account_admin_user"},
         %{
           "type" => type,
           "account_id" => account_id,
           "id" => actor_id
         }
       )
       when type != "account_admin_user" do
    Database.delete_portal_sessions_for_actor(account_id, actor_id)
    Database.delete_oauth_grants_for_actor(account_id, actor_id)

    :ok
  end

  defp handle_update_side_effects(_old_data, _new_data), do: :ok

  defmodule Database do
    alias Portal.ClientToken
    alias Portal.OAuthGrant
    alias Portal.PortalSession
    alias Portal.Safe
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

    # Authorization codes and tokens cascade with their grant.
    def delete_oauth_grants_for_actor(account_id, actor_id) do
      from(g in OAuthGrant,
        where: g.account_id == ^account_id and g.actor_id == ^actor_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
