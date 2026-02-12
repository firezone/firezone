defmodule PortalAPI.Schemas.GatewaySession do
  alias OpenApiSpex.Schema

  defmodule GetSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GatewaySession",
      description: "Gateway Session",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Gateway Session ID"},
        gateway_id: %Schema{type: :string, description: "Gateway ID"},
        gateway_token_id: %Schema{type: :string, description: "Gateway Token ID"},
        last_seen_user_agent: %Schema{
          type: :string,
          description: "User agent at time of session"
        },
        last_seen_remote_ip: %Schema{
          type: :string,
          description: "Remote IP at time of session"
        },
        last_seen_remote_ip_location_region: %Schema{
          type: :string,
          description: "Remote IP location region"
        },
        last_seen_remote_ip_location_city: %Schema{
          type: :string,
          description: "Remote IP location city"
        },
        last_seen_remote_ip_location_lat: %Schema{
          type: :number,
          description: "Remote IP location latitude"
        },
        last_seen_remote_ip_location_lon: %Schema{
          type: :number,
          description: "Remote IP location longitude"
        },
        last_seen_version: %Schema{
          type: :string,
          description: "Gateway version at time of session"
        },
        last_seen_at: %Schema{
          type: :string,
          description: "Timestamp of the session"
        },
        created_at: %Schema{
          type: :string,
          description: "Session creation timestamp"
        }
      },
      required: [
        :id,
        :gateway_id,
        :gateway_token_id,
        :last_seen_at,
        :created_at
      ],
      example: %{
        "id" => "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        "gateway_id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "gateway_token_id" => "6ecc106b-75c1-48a5-846c-14782180c1ff",
        "last_seen_user_agent" => "Linux/6.1.0 connlib/1.4.5 (x86_64)",
        "last_seen_remote_ip" => "1.2.3.4",
        "last_seen_remote_ip_location_region" => "California",
        "last_seen_remote_ip_location_city" => "San Francisco",
        "last_seen_remote_ip_location_lat" => 37.7749,
        "last_seen_remote_ip_location_lon" => -122.4194,
        "last_seen_version" => "1.4.5",
        "last_seen_at" => "2025-01-01T00:00:00Z",
        "created_at" => "2025-01-01T00:00:00Z"
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.GatewaySession

    OpenApiSpex.schema(%{
      title: "GatewaySessionResponse",
      description: "Response schema for single Gateway Session",
      type: :object,
      properties: %{
        data: GatewaySession.GetSchema
      },
      example: %{
        "data" => %{
          "id" => "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
          "gateway_id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "gateway_token_id" => "6ecc106b-75c1-48a5-846c-14782180c1ff",
          "last_seen_user_agent" => "Linux/6.1.0 connlib/1.4.5 (x86_64)",
          "last_seen_remote_ip" => "1.2.3.4",
          "last_seen_remote_ip_location_region" => "California",
          "last_seen_remote_ip_location_city" => "San Francisco",
          "last_seen_remote_ip_location_lat" => 37.7749,
          "last_seen_remote_ip_location_lon" => -122.4194,
          "last_seen_version" => "1.4.5",
          "last_seen_at" => "2025-01-01T00:00:00Z",
          "created_at" => "2025-01-01T00:00:00Z"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.GatewaySession

    OpenApiSpex.schema(%{
      title: "GatewaySessionsResponse",
      description: "Response schema for multiple Gateway Sessions",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Gateway Sessions details",
          type: :array,
          items: GatewaySession.GetSchema
        },
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
            "gateway_id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "gateway_token_id" => "6ecc106b-75c1-48a5-846c-14782180c1ff",
            "last_seen_user_agent" => "Linux/6.1.0 connlib/1.4.5 (x86_64)",
            "last_seen_remote_ip" => "1.2.3.4",
            "last_seen_remote_ip_location_region" => "California",
            "last_seen_remote_ip_location_city" => "San Francisco",
            "last_seen_remote_ip_location_lat" => 37.7749,
            "last_seen_remote_ip_location_lon" => -122.4194,
            "last_seen_version" => "1.4.5",
            "last_seen_at" => "2025-01-01T00:00:00Z",
            "created_at" => "2025-01-01T00:00:00Z"
          }
        ],
        "metadata" => %{
          "limit" => 50,
          "total" => 100,
          "prev_page" => nil,
          "next_page" => "abc123"
        }
      }
    })
  end
end
