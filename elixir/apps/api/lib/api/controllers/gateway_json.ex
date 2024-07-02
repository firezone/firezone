defmodule API.GatewayJSON do
  alias Domain.Gateways
  alias Domain.Repo.Paginator.Metadata

  @doc """
  Renders a list of Gateways.
  """
  def index(%{gateways: gateways, metadata: metadata}) do
    %{data: for(gateway <- gateways, do: data(gateway))}
    |> Map.put(:metadata, metadata(metadata))
  end

  @doc """
  Render a single Gateway
  """
  def show(%{gateway: gateway}) do
    %{data: data(gateway)}
  end

  @doc """
  Render a Gateway Token
  """
  def token(%{gateway_token: token}) do
    %{data: %{gateway_token: token}}
  end

  defp data(%Gateways.Gateway{} = gateway) do
    %{
      id: gateway.id,
      name: gateway.name,
      ipv4: gateway.ipv4,
      ipv6: gateway.ipv6
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
