defmodule Domain.Events.Hooks.Flows do
  @behaviour Domain.Events.Hooks
  alias Domain.{Flows, PubSub, SchemaHelpers}

  @impl true

  # We don't react directly to flow creation events because connection setup
  # is latency sensitive and we've already broadcasted the relevant message from
  # client pid to gateway pid directly.
  def on_insert(_data), do: :ok

  @impl true

  # Flows are never updated
  def on_update(_old_data, _data), do: :ok

  @impl true

  # This will trigger reject_access for any subscribed gateways
  def on_delete(old_data) do
    flow = SchemaHelpers.struct_from_params(Flows.Flow, old_data)
    PubSub.Account.broadcast(flow.account_id, {:deleted, flow})
  end
end
