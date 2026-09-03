defmodule PortalAPI.Schemas.GoogleDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.Google.Directory,
             internal: [:error_email_count, :is_verified, :sync_all_domains]}
    OpenApiSpex.schema(%{
      title: "GoogleDirectory",
      description: "Google Directory",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Directory ID"
        },
        account_id: %Schema{
          example: "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
          type: :string,
          format: :uuid,
          description: "Account ID"
        },
        name: %Schema{example: "Google", type: :string, description: "Directory name"},
        domain: %Schema{
          example: "example.com",
          type: :string,
          description: "Google Workspace domain"
        },
        impersonation_email: %Schema{
          example: "admin@example.com",
          type: :string,
          description: "Impersonation email"
        },
        is_disabled: %Schema{
          example: false,
          type: :boolean,
          description: "Whether directory is disabled"
        },
        disabled_reason: %Schema{
          example: nil,
          type: :string,
          nullable: true,
          description: "Reason for disabling"
        },
        synced_at: %Schema{
          example: "2025-01-15T10:30:00Z",
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Last sync timestamp"
        },
        error_message: %Schema{
          example: nil,
          type: :string,
          nullable: true,
          description: "Last error message"
        },
        errored_at: %Schema{
          example: nil,
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Last error timestamp"
        },
        group_sync_mode: %Schema{
          example: "all",
          type: :string,
          enum: ["all", "filtered", "disabled"],
          description: "Group sync mode"
        },
        orgunit_sync_enabled: %Schema{
          example: true,
          type: :boolean,
          description: "Whether org unit sync is enabled"
        },
        inserted_at: %Schema{
          example: "2025-01-01T00:00:00Z",
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          example: "2025-01-15T10:30:00Z",
          type: :string,
          format: :"date-time",
          description: "Update timestamp"
        }
      },
      required: [
        :account_id,
        :disabled_reason,
        :domain,
        :error_message,
        :errored_at,
        :group_sync_mode,
        :id,
        :impersonation_email,
        :inserted_at,
        :is_disabled,
        :name,
        :orgunit_sync_enabled,
        :synced_at,
        :updated_at
      ]
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
      }
    })
  end
end
