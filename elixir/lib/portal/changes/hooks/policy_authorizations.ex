defmodule Portal.Changes.Hooks.PolicyAuthorizations do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PolicyAuthorization, PubSub}
  import Portal.SchemaHelpers

  @impl true

  # We don't react to policy authorization creation for gateway notification — connection
  # setup is latency sensitive and the message is already sent directly from client pid to
  # gateway pid.
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
