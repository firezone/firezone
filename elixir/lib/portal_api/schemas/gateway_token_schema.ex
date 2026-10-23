defmodule PortalAPI.Schemas.GatewayToken do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.ClientToken,
             internal: [
               :account_id,
               :actor_id,
               :auth_provider_id,
               :auth_provider_name,
               :auth_provider_type,
               :device_id,
               :expires_at,
               :inserted_at,
               :last_used_device,
               :online?,
               :rotated_at,
               :rotated_sibling_id,
               :site_id,
               :updated_at
             ]}
    OpenApiSpex.schema(%{
      title: "GatewayToken",
      description: "Gateway Token",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Gateway Token ID"
        },
        token: %Schema{example: "secret-token-here", type: :string, description: "Gateway Token"}
      },
      required: [:id, :token]
    })

    def map(%Portal.ClientToken{} = token, _map) do
      %{token: Portal.Authentication.encode_fragment!(token)}
    end
  end

  defmodule CreateSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GatewayTokenCreate",
      description: "Attributes of a new single-owner Gateway Token",
      type: :object,
      properties: %{
        actor_id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description:
            "Service account the Gateway connects as. Defaults to the account's " <>
              "Infrastructure service account."
        }
      }
    })
  end

  defmodule CreateRequest do
    require OpenApiSpex
    alias PortalAPI.Schemas.GatewayToken

    OpenApiSpex.schema(%{
      title: "GatewayTokenCreateRequest",
      description: "Request body for creating a single-owner Gateway Token",
      type: :object,
      properties: %{
        gateway_token: GatewayToken.CreateSchema
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.GatewayToken

    OpenApiSpex.schema(%{
      title: "GatewayTokenResponse",
      description: "Response schema for a new Gateway Token",
      type: :object,
      properties: %{
        data: GatewayToken.Schema
      }
    })
  end

  defmodule DeletedResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DeletedGatewayTokenResponse",
      description: "Response schema for a deleted Gateway Token",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            id: %Schema{
              example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
              type: :string,
              format: :uuid,
              description: "Gateway Token ID"
            }
          },
          required: [:id]
        }
      }
    })
  end

  defmodule DeletedAllResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DeletedGatewayTokensResponse",
      description: "Response schema for deleted Gateway Tokens",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            deleted_count: %Schema{
              example: 5,
              type: :integer,
              description: "Number of tokens that were deleted"
            }
          },
          required: [:deleted_count]
        }
      }
    })
  end
end
