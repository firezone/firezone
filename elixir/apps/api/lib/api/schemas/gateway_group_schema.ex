defmodule API.Schemas.GatewayGroup do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GatewayGroup",
      description: "Gateway Group",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Gateway Group ID"},
        name: %Schema{type: :string, description: "Gateway Group Name"}
      },
      required: [:id, :name],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "vpc-us-east"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.GatewayGroup

    OpenApiSpex.schema(%{
      title: "GatewayGroupRequest",
      description: "POST body for creating a Gateway Group",
      type: :object,
      properties: %{
        gateway_group: GatewayGroup.Schema
      },
      required: [:gateway_group],
      example: %{
        "gateway_group" => %{
          "name" => "vpc-us-east"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.GatewayGroup

    OpenApiSpex.schema(%{
      title: "GatewayGroupResponse",
      description: "Response schema for single Gateway Group",
      type: :object,
      properties: %{
        data: GatewayGroup.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "vpc-us-east"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.GatewayGroup

    OpenApiSpex.schema(%{
      title: "GatewayGroupListResponse",
      description: "Response schema for multiple Gateway Groups",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Gateway Group details",
          type: :array,
          items: GatewayGroup.Schema
        },
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "vpc-us-east"
          },
          %{
            "id" => "6301d7d2-4938-4123-87de-282c01cca656",
            "name" => "vpc-us-west"
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
