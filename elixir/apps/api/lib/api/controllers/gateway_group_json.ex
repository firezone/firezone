defmodule API.GatewayGroupJSON do
  alias Domain.Gateways
  alias Domain.Repo.Paginator.Metadata

  @doc """
  Renders a list of Sites / Gateway Groups.
  """
  def index(%{gateway_groups: gateway_groups, metadata: metadata}) do
    %{data: for(group <- gateway_groups, do: data(group))}
    |> Map.put(:metadata, metadata(metadata))
  end

  @doc """
  Render a single Site / Gateway Group
  """
  def show(%{gateway_group: group}) do
    %{data: data(group)}
  end

  defp data(%Gateways.Group{} = group) do
    %{
      id: group.id,
      name: group.name
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
