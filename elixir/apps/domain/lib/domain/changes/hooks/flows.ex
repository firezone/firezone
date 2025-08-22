defmodule Domain.Changes.Hooks.Flows do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, Flows, PubSub}
  import Domain.SchemaHelpers

  @impl true

  # We don't react directly to flow creation events because connection setup
  # is latency sensitive and we've already broadcasted the relevant message from
  # client pid to gateway pid directly.
  def on_insert(_lsn, _data), do: :ok

  @impl true

  # Flows are never updated
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true

  # This will trigger reject_access for any subscribed gateways
  def on_delete(lsn, old_data) do
    flow = struct_from_params(Flows.Flow, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: flow}
    PubSub.Account.broadcast(flow.account_id, change)
  end
end
