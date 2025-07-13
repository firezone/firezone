defmodule API.FlowJSON do
  alias API.Pagination
  alias Domain.Flows.Flow

  @doc """
  Renders a list of flows.
  """
  def index(%{flows: flows, metadata: metadata}) do
    %{
      data: Enum.map(flows, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Renders a single flow.
  """
  def show(%{flow: flow}) do
    %{data: data(flow)}
  end

  defp data(%Flow{} = flow) do
    %{
      id: flow.id,
      policy_id: flow.policy_id,
      client_id: flow.client_id,
      gateway_id: flow.gateway_id,
      resource_id: flow.resource_id,
      token_id: flow.token_id,
      inserted_at: flow.inserted_at
    }
  end
end
