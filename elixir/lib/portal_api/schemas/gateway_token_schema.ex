defmodule PortalAPI.Schemas.GatewayToken do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "GatewayToken",
      description: "Gateway Token",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Gateway Token ID"},
        token: %Schema{type: :string, description: "Gateway Token"}
      },
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "token" => "secret-token-here"
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
            id: %Schema{type: :string, format: :uuid, description: "Gateway Token ID"}
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
