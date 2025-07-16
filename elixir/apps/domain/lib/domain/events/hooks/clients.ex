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
    PubSub.Account.broadcast(client.account_id, {:updated, old_client, client})
  end

  @impl true
  def on_delete(old_data) do
    client = SchemaHelpers.struct_from_params(Clients.Client, old_data)
    PubSub.Account.broadcast(client.account_id, {:deleted, client})

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Domain.Flows.delete_flows_for(client)
  end
end
