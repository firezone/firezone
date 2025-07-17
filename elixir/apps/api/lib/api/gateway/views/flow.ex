defmodule API.Gateway.Views.Flow do
  def render_many(flows) do
    flows
    |> Enum.map(fn {_id, flow} ->
      %{
        client_id: flow.client_id,
        resource_id: flow.resource_id
      }
    end)
    |> Enum.uniq()
  end
end
