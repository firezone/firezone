defmodule PortalAPI.Schemas.Client do
  alias OpenApiSpex.Schema

  defmodule GetSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Client",
      description: "Client",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Client ID"},
        firezone_id: %Schema{
          type: :string,
          nullable: true,
          description:
            "Identifier the Client reports for itself. Null for a Client whose identity " <>
              "comes from an MDM-issued certificate, since a self-reported value could " <>
              "otherwise be used to claim another Client's record."
        },
        actor_id: %Schema{type: :string, format: :uuid, description: "Actor ID"},
        name: %Schema{
          type: :string,
          description: "Client Name"
        },
        ipv4: %Schema{
          type: :string,
          description: "Tunnel IPv4 Address of Client"
        },
        ipv6: %Schema{
          type: :string,
          description: "Tunnel IPv6 Address of Client"
        },
        online: %Schema{
          type: :boolean,
          description: "Online status of Client"
        },
        device_serial: %Schema{
          type: :string,
          nullable: true,
          description: "Device manufacturer serial number (unavailable for mobile devices)"
        },
        device_uuid: %Schema{
          type: :string,
          nullable: true,
          description: "Device manufacturer UUID (unavailable for mobile devices)"
        },
        identifier_for_vendor: %Schema{
          type: :string,
          nullable: true,
          description: "App installation ID (iOS only)"
        },
        firebase_installation_id: %Schema{
          type: :string,
          nullable: true,
          description: "Firebase installation ID (Android only)"
        },
        hostname: %Schema{
          type: :string,
          nullable: true,
          description: "Client hostname (FQDN used for dynamic device pool DNS resolution)"
        },
        last_attested_device_serial: %Schema{
          type: :string,
          nullable: true,
          readOnly: true,
          description: "Device serial number attested by an MDM-provisioned client certificate"
        },
        last_attested_device_uuid: %Schema{
          type: :string,
          nullable: true,
          readOnly: true,
          description: "Device UUID attested by an MDM-provisioned client certificate"
        },
        last_attested_mdm_device_id: %Schema{
          type: :string,
          nullable: true,
          readOnly: true,
          description: "MDM device ID attested by an MDM-provisioned client certificate"
        },
        last_attested_cert_serial: %Schema{
          type: :string,
          nullable: true,
          readOnly: true,
          description: "Serial number of the client certificate used for device verification"
        },
        last_attested_cert_fingerprint: %Schema{
          type: :string,
          nullable: true,
          readOnly: true,
          description: "SHA-256 fingerprint of the client certificate used for device verification"
        },
        last_attested_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          readOnly: true,
          description:
            "When the device last proved possession of an MDM-provisioned client certificate"
        },
        verified_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Client verification timestamp"
        },
        public_key: %Schema{
          type: :string,
          nullable: true,
          description: "WireGuard public key from the latest session"
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
          description: "Client version from the latest session"
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
        },
        created_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Client creation timestamp"
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Client update timestamp"
        }
      },
      required: [
        :actor_id,
        :created_at,
        :device_serial,
        :device_uuid,
        :firebase_installation_id,
        :firezone_id,
        :hostname,
        :id,
        :identifier_for_vendor,
        :ipv4,
        :ipv6,
        :last_attested_at,
        :last_attested_cert_fingerprint,
        :last_attested_cert_serial,
        :last_attested_device_serial,
        :last_attested_device_uuid,
        :last_attested_mdm_device_id,
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
        :updated_at,
        :verified_at
      ],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "firezone_id" => "b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c",
        "actor_id" => "6ecc106b-75c1-48a5-846c-14782180c1ff",
        "name" => "John's Macbook Air",
        "ipv4" => "100.64.0.1",
        "ipv6" => "fd00:2021:1111::1",
        "online" => true,
        "device_serial" => "GCCFX0DBQ6L5",
        "device_uuid" => "7A461FF9-0BE2-64A9-A418-539D9A21827B",
        "identifier_for_vendor" => nil,
        "firebase_installation_id" => nil,
        "hostname" => "johns-macbook.example.com",
        "last_attested_device_serial" => "GCCFX0DBQ6L5",
        "last_attested_device_uuid" => "7A461FF9-0BE2-64A9-A418-539D9A21827B",
        "last_attested_mdm_device_id" => "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
        "last_attested_cert_serial" => "4A:2F:00:8C:11:03:9E:5B",
        "last_attested_cert_fingerprint" => "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        "last_attested_at" => "2025-01-01T00:00:00Z",
        "verified_at" => "2025-01-01T00:00:00Z",
        "public_key" => "WdKAyoA45xJllRUYnFhI5+Y4EjSTs50MzYYHfrIhVAc=",
        "last_seen_at" => "2025-01-01T00:00:00Z",
        "last_seen_version" => "1.5.0",
        "last_seen_user_agent" => "macOS/14.0 apple-client/1.5.0",
        "last_seen_remote_ip" => "203.0.113.10",
        "last_seen_remote_ip_location_region" => "US",
        "last_seen_remote_ip_location_city" => "New York",
        "last_seen_remote_ip_location_lat" => 40.7128,
        "last_seen_remote_ip_location_lon" => -74.006,
        "created_at" => "2025-01-01T00:00:00Z",
        "updated_at" => "2025-01-01T00:00:00Z"
      }
    })
  end

  defmodule PutSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ClientPut",
      description: "Put schema for updating a single Client",
      type: :object,
      properties: %{
        name: %Schema{
          type: :string,
          description: "Client Name"
        }
      },
      required: [:name],
      example: %{
        "name" => "John's Macbook Air"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Client

    OpenApiSpex.schema(%{
      title: "ClientPutRequest",
      description: "PUT body for updating a Client",
      type: :object,
      properties: %{
        client: Client.PutSchema
      },
      required: [:client],
      example: %{
        "client" => %{
          "name" => "John's Macbook Air"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Client

    OpenApiSpex.schema(%{
      title: "ClientResponse",
      description: "Response schema for single Client",
      type: :object,
      properties: %{
        data: Client.GetSchema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Client
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "ClientsResponse",
      description: "Response schema for multiple Clients",
      type: :object,
      properties: %{
        data: %Schema{description: "Clients details", type: :array, items: Client.GetSchema},
        metadata: PaginationMetadata
      }
    })
  end
end
