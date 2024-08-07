defmodule API.Schemas.GatewayGroupToken do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GatewayGroupToken",
      description: "Gateway Group Token",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Gateway Group Token ID"},
        token: %Schema{type: :string, description: "Gateway Group Token"}
      },
      required: [:id, :token],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "token" => "secret-token-here"
      }
    })
  end

  defmodule NewToken do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.GatewayGroupToken

    OpenApiSpex.schema(%{
      title: "NewGatewayGroupTokenResponse",
      description: "Response schema for a new Gateway Group Token",
      type: :object,
      properties: %{
        data: GatewayGroupToken.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "token" => "secret-token-here"
        }
      }
    })
  end

  defmodule DeletedToken do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.GatewayGroupToken

    OpenApiSpex.schema(%{
      title: "DeletedGatewayGroupTokenResponse",
      description: "Response schema for a new Gateway Group Token",
      type: :object,
      properties: %{
        data: GatewayGroupToken.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205"
        }
      }
    })
  end

  defmodule DeletedTokens do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.GatewayGroupToken

    OpenApiSpex.schema(%{
      title: "DeletedGatewayGroupTokenListResponse",
      description: "Response schema for deleted Gateway Group Tokens",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Deleted Gateway Group Tokens",
          type: :array,
          items: GatewayGroupToken.Schema
        }
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205"
          },
          %{
            "id" => "6301d7d2-4938-4123-87de-282c01cca656"
          }
        ]
      }
    })
  end
end
