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
        id: %Schema{type: :string, format: :uuid, description: "Gateway ID"},
        name: %Schema{
          type: :string,
          description: "Gateway Name",
          pattern: "[a-zA-Z][a-zA-Z0-9_]+"
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
        },
        public_key: %Schema{
          type: :string,
          nullable: true,
          description: "WireGuard public key from the latest session"
        },
        last_seen_at: %Schema{
          type: :string,
          nullable: true,
          description: "Timestamp of the latest connection"
        },
        last_seen_version: %Schema{
          type: :string,
          nullable: true,
          description: "Gateway version from the latest session"
        },
        last_seen_user_agent: %Schema{
          type: :string,
          nullable: true,
          description: "User agent from the latest session"
        },
        last_seen_remote_ip: %Schema{
          type: :string,
          nullable: true,
          description: "Remote IP from the latest session"
        },
        last_seen_remote_ip_location_region: %Schema{
          type: :string,
          nullable: true,
          description: "Remote IP region from the latest session"
        },
        last_seen_remote_ip_location_city: %Schema{
          type: :string,
          nullable: true,
          description: "Remote IP city from the latest session"
        },
        last_seen_remote_ip_location_lat: %Schema{
          type: :number,
          nullable: true,
          description: "Remote IP latitude from the latest session"
        },
        last_seen_remote_ip_location_lon: %Schema{
          type: :number,
          nullable: true,
          description: "Remote IP longitude from the latest session"
        }
      },
      required: [:id, :name, :ipv4, :ipv6, :online],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "vpc-us-east",
        "ipv4" => "100.64.0.1",
        "ipv6" => "fd00:2021:1111::1",
        "online" => true,
        "public_key" => "WdKAyoA45xJllRUYnFhI5+Y4EjSTs50MzYYHfrIhVAc=",
        "last_seen_at" => "2025-01-01T00:00:00Z",
        "last_seen_version" => "1.5.0",
        "last_seen_user_agent" => "Linux/6.1.0 connlib/1.5.0",
        "last_seen_remote_ip" => "198.51.100.10",
        "last_seen_remote_ip_location_region" => "US-CA",
        "last_seen_remote_ip_location_city" => "San Francisco",
        "last_seen_remote_ip_location_lat" => 37.7749,
        "last_seen_remote_ip_location_lon" => -122.4194
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
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "GatewaysResponse",
      description: "Response schema for multiple Gateways",
      type: :object,
      properties: %{
        data: %Schema{description: "Gateways details", type: :array, items: Gateway.Schema},
        metadata: PaginationMetadata
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
