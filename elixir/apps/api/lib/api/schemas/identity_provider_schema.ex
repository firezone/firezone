defmodule API.Schemas.IdentityProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IdentityProvider",
      description: "Identity Provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Identity Provider ID"},
        name: %Schema{type: :string, description: "Identity Provider name"}
      },
      required: [:id, :name],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "OIDC Provider"
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.IdentityProvider

    OpenApiSpex.schema(%{
      title: "IdentityProviderResponse",
      description: "Response schema for single Identity Provider",
      type: :object,
      properties: %{
        data: IdentityProvider.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "OIDC Provider"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.IdentityProvider

    OpenApiSpex.schema(%{
      title: "IdentityProviderListResponse",
      description: "Response schema for multiple Identity Providers",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Identity Provider details",
          type: :array,
          items: IdentityProvider.Schema
        },
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "OIDC Provider"
          },
          %{
            "id" => "23ca9d03-c904-42c9-bd38-f89a6d57d3a8",
            "name" => "Okta"
          }
        ],
        "metadata" => %{
          "limit" => 10,
          "total" => 100,
          "prev_page" => "123123425",
          "next_page" => "98776234123"
        }
      }
    })
  end
end
