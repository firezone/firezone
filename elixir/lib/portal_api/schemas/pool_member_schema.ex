defmodule PortalAPI.Schemas.PoolMember do
  alias OpenApiSpex.Schema

  defmodule Schema do
    @behaviour PortalAPI.Schema

    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PoolMember",
      description: "A Client belonging to a static device pool Resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Client ID"},
        name: %Schema{type: :string, description: "Client Name"},
        last_seen_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Last time the Client was seen",
          nullable: true
        }
      },
      required: [:id, :last_seen_at, :name],
      example: %{
        "id" => "7cb89288-1fb3-433e-a522-2d087e45988d",
        "name" => "jane-laptop",
        "last_seen_at" => "2024-01-15T10:30:00Z"
      }
    })

    @impl true
    def struct_module, do: Portal.Device

    @impl true
    def internal do
      [
        :account_id,
        :attested?,
        :client_token_id,
        :firezone_id_merged?,
        :gateway_token_id,
        :gateway_token_rotated_at,
        :last_attested_cert_issuer,
        :site_id,
        :type,
        :actor_id,
        :device_serial,
        :device_uuid,
        :firebase_installation_id,
        :firezone_id,
        :hostname,
        :identifier_for_vendor,
        :inserted_at,
        :ipv4,
        :ipv6,
        :last_attested_at,
        :last_attested_cert_fingerprint,
        :last_attested_cert_serial,
        :last_attested_device_serial,
        :last_attested_device_uuid,
        :last_attested_mdm_device_id,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_remote_ip_location_region,
        :last_seen_user_agent,
        :last_seen_version,
        :online?,
        :public_key,
        :updated_at,
        :verified_at
      ]
    end
  end

  defmodule PatchRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PoolMemberPatchRequest",
      description: """
      PATCH body for adding and removing individual pool members. Both
      operations are idempotent, and `remove` is applied before `add`, so a
      Client named in both ends up in the pool.
      """,
      type: :object,
      properties: %{
        pool_members: %Schema{
          type: :object,
          properties: %{
            add: %Schema{
              type: :array,
              description: "Client IDs to add to the pool",
              items: %Schema{type: :string, format: :uuid, description: "Client ID"}
            },
            remove: %Schema{
              type: :array,
              description: "Client IDs to remove from the pool",
              items: %Schema{type: :string, format: :uuid, description: "Client ID"}
            }
          }
        }
      },
      required: [:pool_members],
      example: %{
        "pool_members" => %{
          "add" => ["7cb89288-1fb3-433e-a522-2d087e45988d"],
          "remove" => ["cc9f561a-444d-4083-ab38-0abc6cf2314c"]
        }
      }
    })
  end

  defmodule PutRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PoolMemberPutRequest",
      description: """
      PUT body replacing the pool's entire membership. Any Client not named
      here is removed from the pool.
      """,
      type: :object,
      properties: %{
        pool_members: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              device_id: %Schema{type: :string, format: :uuid, description: "Client ID"}
            },
            required: [:device_id]
          }
        }
      },
      required: [:pool_members],
      example: %{
        "pool_members" => [
          %{"device_id" => "7cb89288-1fb3-433e-a522-2d087e45988d"},
          %{"device_id" => "cc9f561a-444d-4083-ab38-0abc6cf2314c"}
        ]
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata
    alias PortalAPI.Schemas.PoolMember

    OpenApiSpex.schema(%{
      title: "PoolMemberListResponse",
      description: "Response schema for Pool Members",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Pool member details",
          type: :array,
          items: PoolMember.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end

  defmodule PoolMemberResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PoolMemberResponse",
      description: "Response schema for Pool Member updates",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Pool members",
          properties: %{
            device_ids: %Schema{
              description: "Client IDs currently in the pool",
              type: :array,
              items: %Schema{type: :string, format: :uuid, description: "Client ID"}
            }
          }
        }
      },
      example: %{
        "data" => %{
          "device_ids" => [
            "4ddfa557-7dfc-484f-894c-2024ec3fe9f7",
            "89d22f71-939d-442d-b148-897b730adfb4"
          ]
        }
      }
    })
  end
end
