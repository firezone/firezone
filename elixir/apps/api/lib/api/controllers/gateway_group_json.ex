defmodule API.GatewayGroupJSON do
  alias API.Pagination
  alias Domain.Gateways

  @doc """
  Renders a list of Sites / Gateway Groups.
  """
  def index(%{gateway_groups: gateway_groups, metadata: metadata}) do
    %{
      data: Enum.map(gateway_groups, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Site / Gateway Group
  """
  def show(%{gateway_group: group}) do
    %{data: data(group)}
  end

  @doc """
  Render a Gateway Group Token
  """
  def token(%{gateway_token: token, encoded_token: encoded_token}) do
    %{
      data: %{
        id: token.id,
        token: encoded_token
      }
    }
  end

  @doc """
  Render a deleted Gateway Group Token
  """
  def deleted_token(%{gateway_token: token}) do
    %{
      data: %{
        id: token.id
      }
    }
  end

  @doc """
  Render all deleted Gateway Group Tokens
  """
  def deleted_tokens(%{count: count}) do
    %{data: %{deleted_count: count}}
  end

  defp data(%Gateways.Group{} = group) do
    %{
      id: group.id,
      name: group.name
    }
  end
end
