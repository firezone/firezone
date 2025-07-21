defmodule API.Gateway.Views.Flow do
  def render_many(flows) do
    flows
    |> Enum.map(fn {{client_id, resource_id}, _flow_map} ->
      %{
        client_id: client_id,
        resource_id: resource_id
      }
    end)
  end
end
