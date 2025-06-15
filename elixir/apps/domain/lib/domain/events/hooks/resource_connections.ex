defmodule Domain.Events.Hooks.ResourceConnections do
  @behaviour Domain.Events.Hooks
  alias Domain.Flows

  @impl true
  def on_insert(_data), do: :ok

  @impl true
  def on_update(_old_data, _data), do: :ok

  @impl true
  def on_delete(%{"resource_id" => resource_id} = _old_data) do
    # TODO: WAL
    # The flow expires_at field is not used for any persistence-related reason.
    # Remove it and broadcast directly to subscribed pids to remove the flow
    # from their local state. This hook is called when resources change sites.
    Task.start(fn ->
      {:ok, _flows} = Flows.expire_flows_for_resource_id(resource_id)
    end)

    :ok
  end
end
