defmodule Portal.Changes.Hooks.PolicyAuthorizations do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PolicyAuthorization, PubSub}
  import Portal.SchemaHelpers

  @impl true

  # We don't react directly to policy authorization creation events because connection setup
  # is latency sensitive and we've already broadcasted the relevant message from
  # client pid to gateway pid directly.
  def on_insert(_lsn, _data), do: :ok

  @impl true

  # PolicyAuthorizations are never updated
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true

  # This will trigger reject_access for any subscribed gateways
  def on_delete(lsn, old_data) do
    policy_authorization = struct_from_params(PolicyAuthorization, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: policy_authorization}
    PubSub.Changes.broadcast(policy_authorization.account_id, change)
  end
end
