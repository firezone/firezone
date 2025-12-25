defmodule PortalAPI.Schemas.Gateway do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Gateway",
      description: "Gateway",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Gateway ID"},
        name: %Schema{
          type: :string,
          description: "Gateway Name",
          pattern: ~r/[a-zA-Z][a-zA-Z0-9_]+/
        },
        ipv4: %Schema{
          type: :string,
          description: "IPv4 Address of Gateway"
        },
        ipv6: %Schema{
          type: :string,
          description: "IPv6 Address of Gateway"
        },
        online: %Schema{
          type: :boolean,
          description: "Online status of Gateway"
        }
      },
      required: [:id, :name, :ipv4, :ipv6, :online],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "vpc-us-east",
        "ipv4" => "100.64.0.1",
        "ipv6" => "fd00:2021:1111::1",
        "online" => true
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Gateway

    OpenApiSpex.schema(%{
      title: "GatewayResponse",
      description: "Response schema for single Gateway",
      type: :object,
      properties: %{
        data: Gateway.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "vpc-us-east",
          "ipv4" => "1.2.3.4",
          "ipv6" => "",
          "online" => true
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Gateway

    OpenApiSpex.schema(%{
      title: "GatewaysResponse",
      description: "Response schema for multiple Gateways",
      type: :object,
      properties: %{
        data: %Schema{description: "Gateways details", type: :array, items: Gateway.Schema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "vpc-us-east",
            "ipv4" => "1.2.3.4",
            "ipv6" => "",
            "online" => true
          },
          %{
            "id" => "6ecc106b-75c1-48a5-846c-14782180c1ff",
            "name" => "vpc-us-west",
            "ipv4" => "5.6.7.8",
            "ipv6" => "",
            "online" => true
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
