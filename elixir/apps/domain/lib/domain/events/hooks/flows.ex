defmodule Domain.Events.Hooks.Flows do
  alias Domain.PubSub
  require Logger

  def on_insert(_data) do
    :ok
  end

  def on_update(old_data, data) do
    with {:ok, flow_id} <- Map.fetch(data, "id"),
         {:ok, client_id} <- Map.fetch(data, "client_id"),
         {:ok, resource_id} <- Map.fetch(data, "resource_id") do
      if expired?(data) do
        # Flow has become expired
        broadcast(flow_id, {:expire_flow, flow_id, client_id, resource_id})
      else
        :ok
      end
    else
      :error ->
        Logger.error("Expected keys not found in data",
          old_data: inspect(old_data),
          data: inspect(data)
        )

        :ok
    end
  end

  # During normal operation we don't expect to delete flows, however, this is implemented as a safeguard for cases
  # where we might manually clear flows in a migration or some other mechanism.
  def on_delete(old_data) do
    with {:ok, flow_id} <- Map.fetch(old_data, "id"),
         {:ok, client_id} <- Map.fetch(old_data, "client_id"),
         {:ok, resource_id} <- Map.fetch(old_data, "resource_id") do
      # Sending a broadcast for an already-expired flow should be a no-op
      broadcast(flow_id, {:expire_flow, flow_id, client_id, resource_id})
    else
      :error ->
        Logger.error("Expected keys not found in old_data",
          old_data: inspect(old_data)
        )

        :ok
    end
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

  defp expired?(%{"expires_at" => nil}), do: false

  defp expired?(%{"expires_at" => expires_at}) do
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
