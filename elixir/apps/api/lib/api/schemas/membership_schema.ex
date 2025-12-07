defmodule API.Schemas.Membership do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Membership",
      description: "Membership",
      type: :array,
      items: %Schema{
        type: :object,
        properties: %{
          id: %Schema{type: :string, description: "Actor ID"},
          name: %Schema{type: :string, description: "Actor Name"},
          type: %Schema{type: :string, description: "Actor Type"}
        }
      },
      example: [
        %{
          "id" => "7cb89288-1fb3-433e-a522-2d087e45988d",
          "name" => "John Doe",
          "type" => "account_user"
        }
      ]
    })
  end

  defmodule PatchRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Membership

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
              items: %Schema{type: :string, description: "Actor ID"}
            },
            remove: %Schema{
              type: :array,
              description: "Array of Actor IDs",
              items: %Schema{type: :string, description: "Actor ID"}
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
    alias Ecto.Adapter.Schema
    alias Ecto.Adapter.Schema
    alias Ecto.Adapter.Schema
    alias OpenApiSpex.Schema
    alias API.Schemas.Membership

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
              actor_id: %Schema{type: :string, description: "Actor ID"}
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
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Membership

    OpenApiSpex.schema(%{
      title: "MembershipListResponse",
      description: "Response schema for Memberships",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Membership details",
          type: :array,
          items: Membership.Schema
        },
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "John Doe",
            "type" => "account_user"
          },
          %{
            "id" => "cc9f561a-444d-4083-ab38-0abc6cf2314c",
            "name" => "Jane Smith",
            "type" => "account_admin_user"
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

  defmodule MembershipResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
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
              items: %Schema{type: :string, description: "Actor ID"}
            }
          }
        }
      },
      example: %{
        "data" => %{
          "actor_ids" => [
            "4ddfa557-7dfc-484f-894c-2024ec3fe9f7",
            "89d22f71-939d-442d-b148-897b730adfb4"
          ]
        }
      }
    })
  end
end
