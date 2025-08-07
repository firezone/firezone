defmodule Domain.Changes.Hooks.Clients do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, Clients, Flows, PubSub}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true

  # Soft-delete
  def on_update(lsn, %{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(lsn, old_data)
  end

  # Regular update
  def on_update(lsn, old_data, data) do
    old_client = struct_from_params(Clients.Client, old_data)
    client = struct_from_params(Clients.Client, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_client, struct: client}

    # Unverifying a client
    # This is a special case - we need to delete associated flows when unverifying a client since
    # it could affect connectivity if any policies are based on the verified status.
    if not is_nil(old_client.verified_at) and is_nil(client.verified_at) do
      Flows.delete_flows_for(client)
    end

    PubSub.Account.broadcast(client.account_id, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    client = struct_from_params(Clients.Client, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: client}

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Flows.delete_flows_for(client)

    PubSub.Account.broadcast(client.account_id, change)
  end
end
