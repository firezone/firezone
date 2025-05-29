defmodule Domain.Events.Hooks.Flows do
  alias Domain.PubSub
  require Logger

  def on_insert(_data) do
    :ok
  end

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
      broadcast(flow_id, {:expire_flow, flow_id, client_id, resource_id})
    else
      :ok
    end
  end

  # During normal operation we don't expect to delete flows, however, this is implemented as a safeguard for cases
  # where we might manually clear flows in a migration or some other mechanism.
  def on_delete(
        %{
          "id" => flow_id,
          "client_id" => client_id,
          "resource_id" => resource_id
        } = _old_data
      ) do
    broadcast(flow_id, {:expire_flow, flow_id, client_id, resource_id})
  end

  def subscribe(flow_id) do
    flow_id
    |> topic()
    |> PubSub.subscribe()
  end

  def unsubscribe(flow_id) do
    flow_id
    |> topic()
    |> PubSub.unsubscribe()
  end

  defp expired?(nil), do: false

  defp expired?(expires_at) do
    with {:ok, expires_at, _} <- DateTime.from_iso8601(expires_at) do
      DateTime.compare(DateTime.utc_now(), expires_at) == :gt
    else
      _ -> false
    end
  end

  defp topic(flow_id) do
    "flows:#{flow_id}"
  end

  defp broadcast(flow_id, payload) do
    flow_id
    |> topic()
    |> PubSub.broadcast(payload)
  end
end
