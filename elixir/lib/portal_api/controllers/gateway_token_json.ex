defmodule PortalAPI.GatewayTokenJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.GatewayToken, PortalAPI.Schemas.GatewayToken.Schema,
    computed: [:token],
    # secret_hash and secret_salt are credential material and must never leave
    # the portal.
    internal: [
      :account_id,
      :device_id,
      :inserted_at,
      :rotated_at,
      :rotated_sibling_id,
      :secret_fragment,
      :secret_hash,
      :secret_salt,
      :site_id
    ]
  )

  # `deleted/1` and `deleted_all/1` acknowledge a deletion rather than render a
  # token, so they build their own payloads instead of using the schema.
  def show(%{token: token, encoded_token: encoded_token}) do
    %{data: PortalAPI.JSON.render(token, PortalAPI.Schemas.GatewayToken.Schema, %{token: encoded_token})}
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
end
