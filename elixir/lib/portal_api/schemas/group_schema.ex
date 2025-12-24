defmodule PortalAPI.Schemas.Group do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Group",
      description: "Group",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Group ID"},
        name: %Schema{type: :string, description: "Group Name"},
        entity_type: %Schema{
          type: :string,
          enum: ["group", "org_unit"],
          description: "Entity type"
        },
        directory_id: %Schema{
          type: :string,
          description: "Directory ID this group belongs to",
          nullable: true
        },
        idp_id: %Schema{
          type: :string,
          description: "Identity provider ID for synced groups",
          nullable: true
        },
        last_synced_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Last sync timestamp for synced groups",
          nullable: true
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Last update timestamp"
        }
      },
      required: [:id, :name, :entity_type, :inserted_at, :updated_at],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Engineering",
        "entity_type" => "group",
        "directory_id" => nil,
        "idp_id" => nil,
        "last_synced_at" => nil,
        "inserted_at" => "2024-01-15T10:30:00Z",
        "updated_at" => "2024-01-15T10:30:00Z"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Group

    OpenApiSpex.schema(%{
      title: "GroupRequest",
      description: "POST body for creating an Group",
      type: :object,
      properties: %{
        group: Group.Schema
      },
      required: [:group],
      example: %{
        "group" => %{
          "name" => "Engineering"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Group

    OpenApiSpex.schema(%{
      title: "GroupResponse",
      description: "Response schema for single Group",
      type: :object,
      properties: %{
        data: Group.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Engineering",
          "entity_type" => "group",
          "directory_id" => nil,
          "idp_id" => nil,
          "last_synced_at" => nil,
          "inserted_at" => "2024-01-15T10:30:00Z",
          "updated_at" => "2024-01-15T10:30:00Z"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Group

    OpenApiSpex.schema(%{
      title: "GroupListResponse",
      description: "Response schema for multiple Groups",
      type: :object,
      properties: %{
        data: %Schema{description: "Group details", type: :array, items: Group.Schema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "Engineering",
            "entity_type" => "group",
            "directory_id" => nil,
            "idp_id" => nil,
            "last_synced_at" => nil,
            "inserted_at" => "2024-01-15T10:30:00Z",
            "updated_at" => "2024-01-15T10:30:00Z"
          },
          %{
            "id" => "4ae929a7-1973-43f2-a1a8-9221b91a4c0e",
            "name" => "Finance",
            "entity_type" => "group",
            "directory_id" => "6b4e3a2c-1234-5678-9abc-def012345678",
            "idp_id" => "google-workspace-group-123",
            "last_synced_at" => "2024-01-14T16:00:00Z",
            "inserted_at" => "2024-01-10T08:15:00Z",
            "updated_at" => "2024-01-14T16:45:00Z"
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
