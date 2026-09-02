defmodule PortalAPI.Schemas.Membership do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "Membership",
      description: "Membership",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Actor ID"},
        name: %Schema{type: :string, description: "Actor Name"},
        type: %Schema{type: :string, description: "Actor Type"}
      },
      example: %{
        "id" => "7cb89288-1fb3-433e-a522-2d087e45988d",
        "name" => "John Doe",
        "type" => "account_user"
      }
    })
  end

  defmodule PatchRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MembershipPatchRequest",
      description: "PATCH body for updating Memberships",
      type: :object,
      properties: %{
        memberships: %Schema{
          type: :object,
          properties: %{
            add: %Schema{
              type: :array,
              description: "Array of Actor IDs",
              items: %Schema{type: :string, format: :uuid, description: "Actor ID"}
            },
            remove: %Schema{
              type: :array,
              description: "Array of Actor IDs",
              items: %Schema{type: :string, format: :uuid, description: "Actor ID"}
            }
          }
        }
      },
      required: [:memberships],
      example: %{
        "memberships" => %{
          "add" => ["1234-1234"],
          "remove" => ["2345-2345"]
        }
      }
    })
  end

  defmodule PutRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MembershipPutRequest",
      description: "PUT body for updating Memberships",
      type: :object,
      properties: %{
        memberships: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              actor_id: %Schema{type: :string, format: :uuid, description: "Actor ID"}
            }
          }
        }
      },
      required: [:memberships],
      example: %{
        "memberships" => [
          %{"actor_id" => "1234-1234"},
          %{"actor_id" => "2345-2345"}
        ]
      }
    })
  end

  defmodule ListResponse do
    use PortalAPI.Schemas.Object
    alias PortalAPI.Schemas.Membership
    alias PortalAPI.Schemas.PaginationMetadata

    object(%{
      title: "MembershipListResponse",
      description: "Response schema for Memberships",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Membership details",
          type: :array,
          items: Membership.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end

  defmodule MembershipResponse do
    use PortalAPI.Schemas.Object

    object(%{
      title: "MembershipResponse",
      description: "Response schema for Membership Updates",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Memberships",
          properties: %{
            actor_ids: %Schema{
              description: "Actor IDs",
              type: :array,
              items: %Schema{type: :string, format: :uuid, description: "Actor ID"}
            }
          }
        }
      }
    })
  end
end
