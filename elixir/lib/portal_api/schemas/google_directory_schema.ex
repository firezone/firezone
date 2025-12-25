defmodule PortalAPI.Schemas.GoogleDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GoogleDirectory",
      description: "Google Directory",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Directory ID"},
        account_id: %Schema{type: :string, description: "Account ID"},
        name: %Schema{type: :string, description: "Directory name"},
        domain: %Schema{type: :string, description: "Google Workspace domain"},
        impersonation_email: %Schema{type: :string, description: "Impersonation email"},
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

    OpenApiSpex.schema(%{
      title: "GoogleDirectoryListResponse",
      description: "Response schema for multiple Google Directories",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Google Directory details",
          type: :array,
          items: GoogleDirectory.Schema
        }
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
