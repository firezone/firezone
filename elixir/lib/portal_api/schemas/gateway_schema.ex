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
          description: "Gateway Name"
        },
        ipv4: %Schema{
          type: :string,
          description: "Tunnel IPv4 address (see last_seen_remote_ip for the public IP)"
        },
        ipv6: %Schema{
          type: :string,
          description: "Tunnel IPv6 address (see last_seen_remote_ip for the public IP)"
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
        gateway_token_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "ID of the token this Gateway last connected with. Null until the Gateway " <>
              "connects for the first time."
        },
        rotated_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "When the token identified by `gateway_token_id` was rotated out. Null in " <>
              "the normal case. When set, a replacement token has been minted and this " <>
              "one stays valid only until the Gateway connects with the replacement or " <>
              "#{Portal.GatewayToken.rotation_grace_hours()} hours elapse from this " <>
              "timestamp, whichever comes first - so a non-null value means a rotation " <>
              "is pending and the Gateway has not picked it up yet."
        },
        last_seen_at: %Schema{
          type: :string,
          format: :"date-time",
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
      required: [
        :gateway_token_id,
        :id,
        :ipv4,
        :ipv6,
        :last_seen_at,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_remote_ip_location_region,
        :last_seen_user_agent,
        :last_seen_version,
        :name,
        :online,
        :public_key,
        :rotated_at
      ],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "vpc-us-east",
        "ipv4" => "100.64.0.1",
        "ipv6" => "fd00:2021:1111::1",
        "online" => true,
        "public_key" => "WdKAyoA45xJllRUYnFhI5+Y4EjSTs50MzYYHfrIhVAc=",
        "gateway_token_id" => "0642e09d-b3a2-47e4-9cd1-c2195faeeb67",
        "rotated_at" => nil,
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

  defmodule CreateSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GatewayCreate",
      description: "Create schema for a single Gateway",
      type: :object,
      properties: %{
        name: %Schema{
          type: :string,
          description: "Gateway Name. Randomly generated when omitted."
        }
      },
      example: %{
        "name" => "vpc-us-east"
      }
    })
  end

  defmodule CreateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Gateway

    OpenApiSpex.schema(%{
      title: "GatewayCreateRequest",
      description: "Request body for provisioning a Gateway",
      type: :object,
      properties: %{
        gateway: Gateway.CreateSchema
      },
      example: %{
        "gateway" => %{
          "name" => "vpc-us-east"
        }
      }
    })
  end

  defmodule ProvisionResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Gateway

    OpenApiSpex.schema(%{
      title: "GatewayProvisionResponse",
      description: """
      Response schema for a newly provisioned Gateway. Includes the \
      one-time token secret - it is not shown again.
      """,
      type: :object,
      properties: %{
        data: %Schema{
          allOf: [
            Gateway.Schema,
            %Schema{
              type: :object,
              properties: %{
                token: %Schema{type: :string, description: "One-time Gateway token secret"}
              },
              required: [:token]
            }
          ]
        }
      }
    })
  end

  defmodule UpdateSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GatewayUpdate",
      description: "Update schema for a single Gateway",
      type: :object,
      properties: %{
        name: %Schema{
          type: :string,
          description: "Gateway Name"
        }
      },
      required: [:name],
      example: %{
        "name" => "vpc-us-east"
      }
    })
  end

  defmodule UpdateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Gateway

    OpenApiSpex.schema(%{
      title: "GatewayUpdateRequest",
      description: "Request body for updating a Gateway",
      type: :object,
      properties: %{
        gateway: Gateway.UpdateSchema
      },
      required: [:gateway],
      example: %{
        "gateway" => %{
          "name" => "vpc-us-east"
        }
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
      }
    })
  end
end
