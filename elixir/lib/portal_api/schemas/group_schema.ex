defmodule PortalAPI.Schemas.Group do
  alias OpenApiSpex.Schema

  defmodule Schema do
    @behaviour PortalAPI.Schema

    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Group",
      description: "Group",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Group ID"},
        name: %Schema{type: :string, description: "Group Name"},
        email: %Schema{
          type: :string,
          description: "Group email address for synced groups",
          nullable: true
        },
        entity_type: %Schema{
          type: :string,
          enum: ["group", "org_unit"],
          description: "Entity type"
        },
        directory_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Directory ID this group belongs to",
          nullable: true
        },
        idp_id: %Schema{
          type: :string,
          description: "Identity provider ID for synced groups",
          nullable: true
        },
        synced_at: %Schema{
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
      ],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Engineering",
        "email" => nil,
        "entity_type" => "group",
        "directory_id" => nil,
        "idp_id" => nil,
        "synced_at" => nil,
        "inserted_at" => "2024-01-15T10:30:00Z",
        "updated_at" => "2024-01-15T10:30:00Z"
      }
    })

    @impl true
    def struct_module, do: Portal.Group

    @impl true
    def internal, do: [:account_id, :type]

    @impl true
    def computed, do: [:synced_at]

    @impl true
    def value(:synced_at, %Portal.Group{sync_state: %Portal.GroupSyncState{synced_at: t}}), do: t
    def value(:synced_at, %Portal.Group{}), do: nil
    def value(field, group), do: Map.fetch!(group, field)
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
            name: %Schema{type: :string, description: "Group Name"}
          },
          required: [:name]
        }
      },
      required: [:group],
      example: %{
        "group" => %{
          "name" => "Engineering"
        }
      }
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
            name: %Schema{type: :string, description: "Group Name"}
          }
        }
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
          "email" => nil,
          "entity_type" => "group",
          "directory_id" => nil,
          "idp_id" => nil,
          "synced_at" => nil,
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
