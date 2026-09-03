defmodule PortalAPI.Schemas.PoolMember do
  alias OpenApiSpex.Schema

  defmodule Schema do
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
