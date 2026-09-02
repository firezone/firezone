defmodule PortalAPI.GatewayTokenJSON do
  alias PortalAPI.Pagination

  def index(%{tokens: tokens, metadata: metadata}) do
    %{
      data: Enum.map(tokens, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  def show_metadata(%{token: token}) do
    %{
      data: data(token)
    }
  end

  def show(%{token: token, encoded_token: encoded_token}) do
    %{
      data: %{
        id: token.id,
        token: encoded_token
      }
    }
  end

  def deleted(%{token: token}) do
    %{
      data: %{
        id: token.id
      }
    }
  end

  def deleted_all(%{count: count}) do
    %{
      data: %{
        deleted_count: count
      }
    }
  end

  # device_id is a Gateway on the public API, and the secret columns are never
  # rendered: a token value only exists in the response that created it.
  defp data(token) do
    %{
      id: token.id,
      site_id: token.site_id,
      gateway_id: token.device_id,
      rotated_at: token.rotated_at,
      inserted_at: token.inserted_at
    }
  end
end
