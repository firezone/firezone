defmodule PortalAPI.ClientTokenJSON do
  alias PortalAPI.Pagination

  def index(%{tokens: tokens, metadata: metadata}) do
    %{
      data: Enum.map(tokens, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  def show_secret(%{token: token, encoded_token: encoded_token}) do
    %{
      data:
        data(token)
        |> Map.put(:token, encoded_token)
    }
  end

  def show_metadata(%{token: token}) do
    %{
      data: data(token)
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

  defp data(token) do
    %{
      id: token.id,
      actor_id: token.actor_id,
      expires_at: token.expires_at,
      inserted_at: token.inserted_at,
      updated_at: token.updated_at
    }
  end
end
