defmodule API.GroupJSON do
  alias API.Pagination
  alias Domain.Group

  @doc """
  Renders a list of Groups.
  """
  def index(%{groups: groups, metadata: metadata}) do
    %{
      data: Enum.map(groups, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Group
  """
  def show(%{group: group}) do
    %{data: data(group)}
  end

  defp data(%Group{} = group) do
    %{
      id: group.id,
      name: group.name
    }
  end
end
