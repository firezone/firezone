defmodule API.Gateway.Views.Flow do
  def render(flow, expires_at) do
    %{
      client_id: flow.client_id,
      resource_id: flow.resource_id,
      expires_at: DateTime.to_unix(expires_at, :second)
    }
  end

  def render_many(flows) do
    flows
    |> Enum.map(fn {{client_id, resource_id}, flow_map} ->
      %{
        client_id: client_id,
        resource_id: resource_id,
        expires_at: DateTime.to_unix(flow_map.expires_at, :second)
      }
    end)
  end
end
