defmodule PortalAPI.Schemas.OktaDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "OktaDirectory",
      description: "Okta Directory",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Directory ID"},
        account_id: %Schema{type: :string, description: "Account ID"},
        name: %Schema{type: :string, description: "Directory name"},
        client_id: %Schema{type: :string, description: "Client ID"},
        kid: %Schema{type: :string, description: "Key ID"},
        okta_domain: %Schema{type: :string, description: "Okta domain"},
        error_count: %Schema{type: :integer, description: "Error count"},
        is_disabled: %Schema{type: :boolean, description: "Whether directory is disabled"},
        disabled_reason: %Schema{type: :string, description: "Reason for disabling"},
        synced_at: %Schema{type: :string, format: :datetime, description: "Last sync timestamp"},
        error: %Schema{type: :string, description: "Last error message"},
        error_emailed_at: %Schema{
          type: :string,
          format: :datetime,
          description: "Error email timestamp"
        },
        inserted_at: %Schema{type: :string, format: :datetime, description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :datetime, description: "Update timestamp"}
      },
      required: [:id, :name],
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

    OpenApiSpex.schema(%{
      title: "OktaDirectoryListResponse",
      description: "Response schema for multiple Okta Directories",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Okta Directory details",
          type: :array,
          items: OktaDirectory.Schema
        }
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
