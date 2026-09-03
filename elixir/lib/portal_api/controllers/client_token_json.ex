defmodule PortalAPI.ClientTokenJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.ClientToken, PortalAPI.Schemas.ClientToken.Schema,
    # secret_* fields are credential material and must never leave the portal.
    internal: [
      :account_id,
      :auth_provider_id,
      :auth_provider_name,
      :auth_provider_type,
      :last_used_device,
      :online?,
      :secret_fragment,
      :secret_hash,
      :secret_nonce,
      :secret_salt
    ]
  )

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

  defp data(%Portal.ClientToken{} = token), do: PortalAPI.JSON.render(token, PortalAPI.Schemas.ClientToken.Schema)
end
