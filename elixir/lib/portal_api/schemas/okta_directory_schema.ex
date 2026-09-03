defmodule PortalAPI.Schemas.OktaDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "OktaDirectory",
      description: "Okta Directory",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Directory ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{example: "Okta", type: :string, description: "Directory name"},
        client_id: %Schema{example: "0oa1b2c3d4e5EXAMPLE", type: :string, description: "Client ID"},
        kid: %Schema{example: "kid-2f8a1c9e", type: :string, description: "Key ID"},
        okta_domain: %Schema{example: "example.okta.com", type: :string, description: "Okta domain"},
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
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{type: :string, format: :"date-time", description: "Update timestamp"}
      }
    }))
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.OktaDirectory

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "OktaDirectoryResponse",
      description: "Response schema for single Okta Directory",
      type: :object,
      properties: %{
        data: OktaDirectory.Schema
      }
    }))
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.OktaDirectory
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "OktaDirectoryListResponse",
      description: "Response schema for multiple Okta Directories",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Okta Directory details",
          type: :array,
          items: OktaDirectory.Schema
        },
        metadata: PaginationMetadata
      }
    }))
  end
end
