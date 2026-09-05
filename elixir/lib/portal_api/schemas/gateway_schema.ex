defmodule PortalAPI.Schemas.Gateway do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.Device,
             internal: [
               :account_id,
               :actor_id,
               :attested?,
               :posture,
               :client_token_id,
               :device_serial,
               :device_uuid,
               :firebase_installation_id,
               :firezone_id,
               :firezone_id_merged?,
               :gateway_token_rotated_at,
               :hostname,
               :identifier_for_vendor,
               :inserted_at,
               :last_attested_at,
               :last_attested_cert_fingerprint,
               :last_attested_cert_issuer,
               :last_attested_cert_serial,
               :last_attested_device_serial,
               :last_attested_device_uuid,
               :last_attested_mdm_device_id,
               :online?,
               :provisioned_token,
               :site_id,
               :type,
               :updated_at,
               :verified_at
             ]}
    OpenApiSpex.schema(%{
      title: "Gateway",
      description: "Gateway",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Gateway ID"
        },
        name: %Schema{
          example: "vpc-us-east",
          type: :string,
          description: "Gateway Name"
        },
        ipv4: %Schema{
          example: "100.64.0.1",
          type: :string,
          description: "Tunnel IPv4 address (see last_seen_remote_ip for the public IP)"
        },
        ipv6: %Schema{
          example: "fd00:2021:1111::1",
          type: :string,
          description: "Tunnel IPv6 address (see last_seen_remote_ip for the public IP)"
        },
        online: %Schema{
          example: true,
          type: :boolean,
          description: "Online status of Gateway"
        },
        public_key: %Schema{
          example: "WdKAyoA45xJllRUYnFhI5+Y4EjSTs50MzYYHfrIhVAc=",
          type: :string,
          nullable: true,
          description: "WireGuard public key from the latest session"
        },
        gateway_token_id: %Schema{
          example: "0642e09d-b3a2-47e4-9cd1-c2195faeeb67",
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "ID of the token this Gateway last connected with. Null until the Gateway " <>
              "connects for the first time."
        },
        rotated_at: %Schema{
          example: nil,
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
          example: "2025-01-01T00:00:00Z",
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Timestamp of the latest connection"
        },
        last_seen_version: %Schema{
          example: "1.5.0",
          type: :string,
          nullable: true,
          description: "Gateway version from the latest session"
        },
        last_seen_user_agent: %Schema{
          example: "Linux/6.1.0 connlib/1.5.0",
          type: :string,
          nullable: true,
          description: "User agent from the latest session"
        },
        last_seen_remote_ip: %Schema{
          example: "198.51.100.10",
          type: :string,
          nullable: true,
          description: "Remote IP from the latest session"
        },
        last_seen_remote_ip_location_region: %Schema{
          example: "US-CA",
          type: :string,
          nullable: true,
          description: "Remote IP region from the latest session"
        },
        last_seen_remote_ip_location_city: %Schema{
          example: "San Francisco",
          type: :string,
          nullable: true,
          description: "Remote IP city from the latest session"
        },
        last_seen_remote_ip_location_lat: %Schema{
          example: 37.7749,
          type: :number,
          nullable: true,
          description: "Remote IP latitude from the latest session"
        },
        last_seen_remote_ip_location_lon: %Schema{
          example: -122.4194,
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
      ]
    })

    def map(%Portal.Device{provisioned_token: nil} = device, _map) do
      %{online: device.online?, rotated_at: device.gateway_token_rotated_at}
    end

    def map(%Portal.Device{provisioned_token: token} = device, map) do
      device
      |> Map.put(:provisioned_token, nil)
      |> map(map)
      |> Map.put(:token, Portal.Authentication.encode_fragment!(token))
    end
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
          example: "vpc-us-east",
          type: :string,
          description: "Gateway Name. Randomly generated when omitted."
        }
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
          example: "vpc-us-east",
          type: :string,
          description: "Gateway Name"
        }
      },
      required: [:name]
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
      required: [:gateway]
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
