defmodule PortalAPI.Schemas.OktaDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
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
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Okta",
        "okta_domain" => "example.okta.com"
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
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Okta"
        }
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
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "Okta"
          }
        ]
      }
    })
  end
end
