defmodule Domain.Events.Hooks.GatewayGroups do
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
  def on_update(old_data, data) do
    old_gateway_group = SchemaHelpers.struct_from_params(Gateways.Group, old_data)
    gateway_group = SchemaHelpers.struct_from_params(Gateways.Group, data)

    PubSub.Account.broadcast(
      gateway_group.account_id,
      {:updated, old_gateway_group, gateway_group}
    )
  end

  @impl true

  # Deleting a gateway group will delete the associated resource connection, where
  # we handle removing it from the client's resource list.
  def on_delete(_old_data), do: :ok
end
