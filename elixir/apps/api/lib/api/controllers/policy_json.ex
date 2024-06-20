defmodule API.PolicyJSON do
  alias Domain.Policies
  alias Domain.Repo.Paginator.Metadata

  @doc """
  Renders a list of Policies.
  """
  def index(%{policies: policies, metadata: metadata}) do
    %{data: for(policy <- policies, do: data(policy))}
    |> Map.put(:metadata, metadata(metadata))
  end

  @doc """
  Render a single Policy
  """
  def show(%{policy: policy}) do
    %{data: data(policy)}
  end

  defp data(%Policies.Policy{} = policy) do
    %{
      id: policy.id,
      actor_group_id: policy.actor_group_id,
      resource_id: policy.resource_id,
      description: policy.description
    }
  end

  defp metadata(%Metadata{} = metadata) do
    %{
      count: metadata.count,
      limit: metadata.limit,
      next_page: metadata.next_page_cursor,
      prev_page: metadata.previous_page_cursor
    }
  end
end
