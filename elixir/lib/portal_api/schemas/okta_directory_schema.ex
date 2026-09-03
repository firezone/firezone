defmodule PortalAPI.Schemas.OktaDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder, for: Portal.Okta.Directory}
    OpenApiSpex.schema(%{
      title: "OktaDirectory",
      description: "Okta Directory",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Directory ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{type: :string, description: "Directory name"},
        client_id: %Schema{type: :string, description: "Client ID"},
        kid: %Schema{type: :string, description: "Key ID"},
        okta_domain: %Schema{type: :string, description: "Okta domain"},
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
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{type: :string, format: :"date-time", description: "Update timestamp"}
      },
      required: [
        :account_id,
        :client_id,
        :disabled_reason,
        :error_message,
        :errored_at,
        :id,
        :inserted_at,
        :is_disabled,
        :kid,
        :name,
        :okta_domain,
        :synced_at,
        :updated_at
      ],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "account_id" => "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
        "name" => "Okta",
        "client_id" => "0oa1b2c3d4e5EXAMPLE",
        "kid" => "kid-2f8a1c9e",
        "okta_domain" => "example.okta.com",
        "is_disabled" => false,
        "disabled_reason" => nil,
        "synced_at" => "2025-01-15T10:30:00Z",
        "error_message" => nil,
        "errored_at" => nil,
        "inserted_at" => "2025-01-01T00:00:00Z",
        "updated_at" => "2025-01-15T10:30:00Z"
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.OktaDirectory

    OpenApiSpex.schema(%{
      title: "OktaDirectoryResponse",
      description: "Response schema for single Okta Directory",
      type: :object,
      properties: %{
        data: OktaDirectory.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.OktaDirectory
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
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
    })
  end
end
