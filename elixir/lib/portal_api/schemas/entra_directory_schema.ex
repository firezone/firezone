defmodule PortalAPI.Schemas.EntraDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "EntraDirectory",
      description: "Entra Directory",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Directory ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{example: "Entra", type: :string, description: "Directory name"},
        tenant_id: %Schema{example: "12345678-1234-1234-1234-123456789012", type: :string, description: "Microsoft Entra tenant ID"},
        is_disabled: %Schema{type: :boolean, description: "Whether directory is disabled"},
        disabled_reason: %Schema{example: "Sync failed on 5 consecutive attempts",
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
        error_message: %Schema{example: "invalid_grant: token has expired or been revoked",
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
        email_field: %Schema{
          type: :string,
          description: "Graph API user field to use as email",
          enum: ["mail", "userPrincipalName"]
        },
        sync_all_groups: %Schema{type: :boolean, description: "Sync all groups"},
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{type: :string, format: :"date-time", description: "Update timestamp"}
      }
    })
  end

  defmodule Response do
    use PortalAPI.Schemas.Object
    alias PortalAPI.Schemas.EntraDirectory

    object(%{
      title: "EntraDirectoryResponse",
      description: "Response schema for single Entra Directory",
      type: :object,
      properties: %{
        data: EntraDirectory.Schema
      }
    })
  end

  defmodule ListResponse do
    use PortalAPI.Schemas.Object
    alias PortalAPI.Schemas.EntraDirectory
    alias PortalAPI.Schemas.PaginationMetadata

    object(%{
      title: "EntraDirectoryListResponse",
      description: "Response schema for multiple Entra Directories",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Entra Directory details",
          type: :array,
          items: EntraDirectory.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
