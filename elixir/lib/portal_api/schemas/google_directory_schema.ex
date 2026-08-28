defmodule PortalAPI.Schemas.GoogleDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "GoogleDirectory",
      description: "Google Directory",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Directory ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{type: :string, description: "Directory name"},
        domain: %Schema{type: :string, description: "Google Workspace domain"},
        impersonation_email: %Schema{type: :string, description: "Impersonation email"},
        is_disabled: %Schema{type: :boolean, description: "Whether directory is disabled"},
        disabled_reason: %Schema{
          type: :string,
          nullable: true,
          description: "Reason for disabling"
        },
        synced_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Last sync timestamp"
        },
        error_message: %Schema{
          type: :string,
          nullable: true,
          description: "Last error message"
        },
        errored_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Last error timestamp"
        },
        group_sync_mode: %Schema{
          type: :string,
          enum: ["all", "filtered", "disabled"],
          description: "Group sync mode"
        },
        orgunit_sync_enabled: %Schema{
          type: :boolean,
          description: "Whether org unit sync is enabled"
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{type: :string, format: :"date-time", description: "Update timestamp"}
      },
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Google",
        "domain" => "example.com"
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.GoogleDirectory

    OpenApiSpex.schema(%{
      title: "GoogleDirectoryResponse",
      description: "Response schema for single Google Directory",
      type: :object,
      properties: %{
        data: GoogleDirectory.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Google"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.GoogleDirectory
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "GoogleDirectoryListResponse",
      description: "Response schema for multiple Google Directories",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Google Directory details",
          type: :array,
          items: GoogleDirectory.Schema
        },
        metadata: PaginationMetadata
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "Google"
          }
        ]
      }
    })
  end
end
