defmodule API.PolicyJSON do
  alias API.Pagination

  @doc """
  Renders a list of Policies.
  """
  def index(%{policies: policies, metadata: metadata}) do
    %{
      data: Enum.map(policies, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Policy
  """
  def show(%{policy: policy}) do
    %{data: data(policy)}
  end

  defp data(%Domain.Policy{} = policy) do
    %{
      id: policy.id,
      group_id: policy.group_id,
      resource_id: policy.resource_id,
      description: policy.description
    }
  end
end
