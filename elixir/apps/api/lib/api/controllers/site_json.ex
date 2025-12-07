defmodule API.SiteJSON do
  alias API.Pagination

  @doc """
  Renders a list of Sites.
  """
  def index(%{sites: sites, metadata: metadata}) do
    %{
      data: Enum.map(sites, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Site
  """
  def show(%{site: site}) do
    %{data: data(site)}
  end

  @doc """
  Render a Site Token
  """
  def token(%{token: token, encoded_token: encoded_token}) do
    %{
      data: %{
        id: token.id,
        token: encoded_token
      }
    }
  end

  @doc """
  Render a deleted Site Token
  """
  def deleted_token(%{token: token}) do
    %{
      data: %{
        id: token.id
      }
    }
  end

  @doc """
  Render all deleted Site Tokens
  """
  def deleted_tokens(%{count: count}) do
    %{data: %{deleted_count: count}}
  end

  defp data(%Domain.Site{} = site) do
    %{
      id: site.id,
      name: site.name
    }
  end
end
