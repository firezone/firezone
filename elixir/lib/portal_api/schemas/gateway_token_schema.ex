defmodule API.Schemas.GatewayToken do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GatewayToken",
      description: "Gateway Token",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Gateway Token ID"},
        token: %Schema{type: :string, description: "Gateway Token"}
      },
      required: [:id, :token],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "token" => "secret-token-here"
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias API.Schemas.GatewayToken

    OpenApiSpex.schema(%{
      title: "GatewayTokenResponse",
      description: "Response schema for a new Gateway Token",
      type: :object,
      properties: %{
        data: GatewayToken.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "token" => "secret-token-here"
        }
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
            id: %Schema{type: :string, description: "Gateway Token ID"}
          },
          required: [:id]
        }
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205"
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
      },
      example: %{
        "data" => %{
          "deleted_count" => 5
        }
      }
    })
  end
end
