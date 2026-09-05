defmodule PortalAPI.Schemas.Group do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder, for: Portal.Group, internal: [:account_id, :type]}
    OpenApiSpex.schema(%{
      title: "Group",
      description: "Group",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Group ID"
        },
        name: %Schema{example: "Engineering", type: :string, description: "Group Name"},
        email: %Schema{
          example: nil,
          type: :string,
          description: "Group email address for synced groups",
          nullable: true
        },
        entity_type: %Schema{
          example: "group",
          type: :string,
          enum: ["group", "org_unit"],
          description: "Entity type"
        },
        directory_id: %Schema{
          example: nil,
          type: :string,
          format: :uuid,
          description: "Directory ID this group belongs to",
          nullable: true
        },
        idp_id: %Schema{
          example: nil,
          type: :string,
          description: "Identity provider ID for synced groups",
          nullable: true
        },
        synced_at: %Schema{
          example: nil,
          type: :string,
          format: :"date-time",
          description: "Last sync timestamp for synced groups",
          nullable: true
        },
        inserted_at: %Schema{
          example: "2024-01-15T10:30:00Z",
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          example: "2024-01-15T10:30:00Z",
          type: :string,
          format: :"date-time",
          description: "Last update timestamp"
        }
      },
      required: [
        :directory_id,
        :email,
        :entity_type,
        :id,
        :idp_id,
        :inserted_at,
        :name,
        :synced_at,
        :updated_at
      ]
    })

    def map(%Portal.Group{synced_at: synced_at}, _map), do: %{synced_at: synced_at}
  end

  defmodule CreateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GroupCreateRequest",
      description: "POST body for creating a Group",
      type: :object,
      properties: %{
        group: %Schema{
          type: :object,
          properties: %{
            name: %Schema{example: "Engineering", type: :string, description: "Group Name"}
          },
          required: [:name]
        }
      },
      required: [:group]
    })
  end

  defmodule UpdateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GroupUpdateRequest",
      description:
        "PATCH/PUT body for updating a Group. All fields are optional; omitted fields keep " <>
          "their current value.",
      type: :object,
      properties: %{
        group: %Schema{
          type: :object,
          properties: %{
            name: %Schema{example: "Engineering", type: :string, description: "Group Name"}
          }
        }
      },
      required: [:group]
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
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Group
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "GroupListResponse",
      description: "Response schema for multiple Groups",
      type: :object,
      properties: %{
        data: %Schema{description: "Group details", type: :array, items: Group.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
