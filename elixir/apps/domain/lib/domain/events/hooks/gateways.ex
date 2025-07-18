defmodule Domain.Events.Hooks.Gateways do
  @behaviour Domain.Events.Hooks
  alias Domain.{Gateways, PubSub, SchemaHelpers}

  @impl true
  def on_insert(_data), do: :ok

  # Soft-delete
  @impl true
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(_old_data, _data), do: :ok

  @impl true
  def on_delete(old_data) do
    gateway = SchemaHelpers.struct_from_params(Gateways.Gateway, old_data)

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Domain.Flows.delete_flows_for(gateway)

    PubSub.Account.broadcast(gateway.account_id, {:deleted, gateway})
  end
end
