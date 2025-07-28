defmodule API.Gateway.Views.Flow do
  def render(flow, expires_at_unix) do
    %{
      client_id: flow.client_id,
      resource_id: flow.resource_id,
      expires_at: expires_at_unix
    }
  end

  def render_many(cache) do
    cache
    |> Enum.map(fn {{cid_bytes, rid_bytes}, flow_map} ->
      # Use longest expiration to minimize unnecessary access churn
      expires_at_unix = Enum.max(Map.values(flow_map))

      %{
        client_id: Ecto.UUID.load!(cid_bytes),
        resource_id: Ecto.UUID.load!(rid_bytes),
        expires_at: expires_at_unix
      }
    end)
  end
end
