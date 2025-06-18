# TODO: WAL
# Move side-effects from flows to state table in clients and gateways
defmodule Domain.Events.Hooks.Flows do
  @behaviour Domain.Events.Hooks
  alias Domain.PubSub
  require Logger

  @impl true
  def on_insert(_data), do: :ok

  @impl true
  def on_update(
        _old_data,
        %{
          "id" => flow_id,
          "client_id" => client_id,
          "resource_id" => resource_id,
          "expires_at" => expires_at
        } = _data
      ) do
    if expired?(expires_at) do
      # Flow has become expired
      PubSub.Flow.broadcast(flow_id, {:expire_flow, flow_id, client_id, resource_id})
    else
      :ok
    end
  end

  # During normal operation we don't expect to delete flows, however, this is implemented as a safeguard for cases
  # where we might manually clear flows in a migration or some other mechanism.
  @impl true
  def on_delete(
        %{
          "id" => flow_id,
          "client_id" => client_id,
          "resource_id" => resource_id
        } = _old_data
      ) do
    PubSub.Flow.broadcast(flow_id, {:expire_flow, flow_id, client_id, resource_id})
  end

  defp expired?(nil), do: false

  defp expired?(expires_at) do
    with {:ok, expires_at, _} <- DateTime.from_iso8601(expires_at) do
      DateTime.compare(DateTime.utc_now(), expires_at) == :gt
    else
      _ -> false
    end
  end
end
