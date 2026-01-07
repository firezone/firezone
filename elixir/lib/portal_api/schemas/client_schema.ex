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
        id: %Schema{type: :string, description: "Client ID"},
        actor_id: %Schema{type: :string, description: "Actor ID"},
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
        last_seen_user_agent: %Schema{
          type: :string,
          description: "Last seen user agent"
        },
        last_seen_remote_ip: %Schema{
          type: :string,
          description: "Last seen remote IP"
        },
        last_seen_remote_ip_location_region: %Schema{
          type: :string,
          description: "Last seen remote IP location region"
        },
        last_seen_remote_ip_location_city: %Schema{
          type: :string,
          description: "Last seen remote IP location city"
        },
        last_seen_remote_ip_location_lat: %Schema{
          type: :number,
          description: "Last seen remote IP location latitude"
        },
        last_seen_remote_ip_location_lon: %Schema{
          type: :number,
          description: "Last seen remote IP location longitude"
        },
        last_seen_version: %Schema{
          type: :string,
          description: "Last seen version"
        },
        last_seen_at: %Schema{
          type: :string,
          description: "Last seen at"
        },
        device_serial: %Schema{
          type: :string,
          description: "Device manufacturer serial number (unavailable for mobile devices)"
        },
        device_uuid: %Schema{
          type: :string,
          description: "Device manufacturer UUID (unavailable for mobile devices)"
        },
        identifier_for_vendor: %Schema{
          type: :string,
          description: "App installation ID (iOS only)"
        },
        firebase_installation_id: %Schema{
          type: :string,
          description: "Firebase installation ID (Android only)"
        },
        verified_at: %Schema{
          type: :string,
          description: "Client verification timestamp"
        },
        created_at: %Schema{
          type: :string,
          description: "Client creation timestamp"
        },
        updated_at: %Schema{
          type: :string,
          description: "Client update timestamp"
        }
      },
      required: [
        :id,
        :actor_id,
        :external_id,
        :name,
        :ipv4,
        :ipv6,
        :online,
        :last_seen_user_agent,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_region,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_version,
        :last_seen_at,
        :created_at,
        :updated_at
      ],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "external_id" => "b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c",
        "actor_id" => "6ecc106b-75c1-48a5-846c-14782180c1ff",
        "name" => "John's Macbook Air",
        "ipv4" => "100.64.0.1",
        "ipv6" => "fd00:2021:1111::1",
        "online" => true,
        "last_seen_user_agent" => "Mac OS/15.1.1 connlib/1.4.5 (arm64; 24.1.0)",
        "last_seen_remote_ip" => "1.2.3.4",
        "last_seen_remote_ip_location_region" => "California",
        "last_seen_remote_ip_location_city" => "San Francisco",
        "last_seen_remote_ip_location_lat" => 37.7749,
        "last_seen_remote_ip_location_lon" => -122.4194,
        "last_seen_version" => "1.4.5",
        "last_seen_at" => "2025-01-01T00:00:00Z",
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
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "external_id" => "b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c",
          "actor_id" => "6ecc106b-75c1-48a5-846c-14782180c1ff",
          "name" => "John's Macbook Air",
          "ipv4" => "100.64.0.1",
          "ipv6" => "fd00:2021:1111::1",
          "online" => true,
          "last_seen_user_agent" => "Mac OS/15.1.1 connlib/1.4.5 (arm64; 24.1.0)",
          "last_seen_remote_ip" => "1.2.3.4",
          "last_seen_remote_ip_location_region" => "California",
          "last_seen_remote_ip_location_city" => "San Francisco",
          "last_seen_remote_ip_location_lat" => 37.7749,
          "last_seen_remote_ip_location_lon" => -122.4194,
          "last_seen_version" => "1.4.5",
          "last_seen_at" => "2025-01-01T00:00:00Z",
          "device_serial" => "GCCFX0DBQ6L5",
          "device_uuid" => "7A461FF9-0BE2-64A9-A418-539D9A21827B",
          "identifier_for_vendor" => nil,
          "firebase_installation_id" => nil,
          "verified_at" => "2025-01-01T00:00:00Z",
          "created_at" => "2025-01-01T00:00:00Z",
          "updated_at" => "2025-01-01T00:00:00Z"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Client

    OpenApiSpex.schema(%{
      title: "ClientsResponse",
      description: "Response schema for multiple Clients",
      type: :object,
      properties: %{
        data: %Schema{description: "Clients details", type: :array, items: Client.GetSchema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "external_id" => "b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c",
            "actor_id" => "6ecc106b-75c1-48a5-846c-14782180c1ff",
            "name" => "John's Macbook Air",
            "ipv4" => "100.64.0.1",
            "ipv6" => "fd00:2021:1111::1",
            "online" => true,
            "last_seen_user_agent" => "Mac OS/15.1.1 connlib/1.4.5 (arm64; 24.1.0)",
            "last_seen_remote_ip" => "1.2.3.4",
            "last_seen_remote_ip_location_region" => "California",
            "last_seen_remote_ip_location_city" => "San Francisco",
            "last_seen_remote_ip_location_lat" => 37.7749,
            "last_seen_remote_ip_location_lon" => -122.4194,
            "last_seen_version" => "1.4.5",
            "last_seen_at" => "2025-01-01T00:00:00Z",
            "device_serial" => "GCCFX0DBQ6L5",
            "device_uuid" => "7A461FF9-0BE2-64A9-A418-539D9A21827B",
            "identifier_for_vendor" => nil,
            "firebase_installation_id" => nil,
            "verified_at" => "2025-01-01T00:00:00Z",
            "created_at" => "2025-01-01T00:00:00Z",
            "updated_at" => "2025-01-01T00:00:00Z"
          },
          %{
            "id" => "9a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "external_id" => "6c37c0042f40bbb16e007d0d6c8e77c0ac2cab3cc3b923c42d1157a934e436ac",
            "actor_id" => "2ecc106b-75c1-48a5-846c-14782180c1ff",
            "name" => "iPad",
            "ipv4" => "100.64.0.2",
            "ipv6" => "fd00:2021:1111::2",
            "online" => false,
            "last_seen_user_agent" => "iOS/18.3.1 connlib/1.4.6 (24.3.0)",
            "last_seen_remote_ip" => "1.2.3.4",
            "last_seen_remote_ip_location_region" => "California",
            "last_seen_remote_ip_location_city" => "San Francisco",
            "last_seen_remote_ip_location_lat" => 37.7749,
            "last_seen_remote_ip_location_lon" => -122.4194,
            "last_seen_version" => "1.4.6",
            "last_seen_at" => "2025-01-01T00:00:00Z",
            "device_serial" => nil,
            "device_uuid" => nil,
            "identifier_for_vendor" => "7A461FF9-0BE2-64A9-A418-539D9A21827B",
            "firebase_installation_id" => nil,
            "verified_at" => nil,
            "created_at" => "2025-01-01T00:00:00Z",
            "updated_at" => "2025-01-01T00:00:00Z"
          }
        ],
        "metadata" => %{
          "limit" => 2,
          "total" => 100,
          "prev_page" => "123123425",
          "next_page" => "98776234123"
        }
      }
    })
  end
end
