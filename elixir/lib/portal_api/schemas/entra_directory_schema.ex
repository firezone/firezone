defmodule PortalAPI.Schemas.EntraDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder, for: Portal.Entra.Directory}
    OpenApiSpex.schema(%{
      title: "EntraDirectory",
      description: "Entra Directory",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Directory ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{type: :string, description: "Directory name"},
        tenant_id: %Schema{type: :string, description: "Microsoft Entra tenant ID"},
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
      },
      required: [
        :account_id,
        :disabled_reason,
        :email_field,
        :error_message,
        :errored_at,
        :id,
        :inserted_at,
        :is_disabled,
        :name,
        :sync_all_groups,
        :synced_at,
        :tenant_id,
        :updated_at
      ],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "account_id" => "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
        "name" => "Entra",
        "tenant_id" => "12345678-1234-1234-1234-123456789012",
        "email_field" => "userPrincipalName",
        "sync_all_groups" => false,
        "is_disabled" => false,
        "disabled_reason" => nil,
        "synced_at" => "2025-01-15T10:30:00Z",
        "error_message" => nil,
        "errored_at" => nil,
        "inserted_at" => "2025-01-01T00:00:00Z",
        "updated_at" => "2025-01-15T10:30:00Z"
      }
    })

    # Struct fields deliberately withheld from the API.
    def internal do
      [
        :error_email_count,
        :groups_subscription_id,
        :is_verified,
        :subscriptions_expire_at,
        :users_subscription_id
      ]
    end
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.EntraDirectory

    OpenApiSpex.schema(%{
      title: "EntraDirectoryResponse",
      description: "Response schema for single Entra Directory",
      type: :object,
      properties: %{
        data: EntraDirectory.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.EntraDirectory
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
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
