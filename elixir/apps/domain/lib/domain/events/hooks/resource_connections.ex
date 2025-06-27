defmodule Domain.Events.Hooks.ResourceConnections do
  @behaviour Domain.Events.Hooks
  alias Domain.Flows

  @impl true
  def on_insert(_data), do: :ok

  @impl true
  def on_update(_old_data, _data), do: :ok

  @impl true
  def on_delete(%{"account_id" => account_id, "resource_id" => resource_id} = _old_data) do
    # TODO: WAL
    # Broadcast flow side effects directly
    #  This hook is called when resources change sites.
    Task.start(fn ->
      :ok = Flows.expire_flows_for_resource_id(account_id, resource_id)
    end)

    :ok
  end
end
