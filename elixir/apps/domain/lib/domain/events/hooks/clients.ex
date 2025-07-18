defmodule Domain.Events.Hooks.Clients do
  @behaviour Domain.Events.Hooks
  alias Domain.{Clients, SchemaHelpers, PubSub}

  @impl true
  def on_insert(_data), do: :ok

  @impl true

  # Soft-delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(old_data, data) do
    old_client = SchemaHelpers.struct_from_params(Clients.Client, old_data)
    client = SchemaHelpers.struct_from_params(Clients.Client, data)

    # Unverifying a client
    # This is a special case - we need to delete associated flows when unverifying a client since
    # it could affect connectivity if any policies are based on the verified status.
    if not is_nil(old_client.verified_at) and is_nil(client.verified_at) do
      Domain.Flows.delete_flows_for(client)
    end

    PubSub.Account.broadcast(client.account_id, {:updated, old_client, client})
  end

  @impl true
  def on_delete(old_data) do
    client = SchemaHelpers.struct_from_params(Clients.Client, old_data)

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Domain.Flows.delete_flows_for(client)

    PubSub.Account.broadcast(client.account_id, {:deleted, client})
  end
end
