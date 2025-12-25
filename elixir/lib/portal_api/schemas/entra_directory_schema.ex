defmodule PortalAPI.Schemas.EntraDirectory do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "EntraDirectory",
      description: "Entra Directory",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Directory ID"},
        account_id: %Schema{type: :string, description: "Account ID"},
        name: %Schema{type: :string, description: "Directory name"},
        tenant_id: %Schema{type: :string, description: "Microsoft Entra tenant ID"},
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
        sync_all_groups: %Schema{type: :boolean, description: "Sync all groups"},
        inserted_at: %Schema{type: :string, format: :datetime, description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :datetime, description: "Update timestamp"}
      },
      required: [:id, :name],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Entra",
        "tenant_id" => "12345678-1234-1234-1234-123456789012"
      }
    })
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
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Entra"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.EntraDirectory

    OpenApiSpex.schema(%{
      title: "EntraDirectoryListResponse",
      description: "Response schema for multiple Entra Directories",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Entra Directory details",
          type: :array,
          items: EntraDirectory.Schema
        }
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "Entra"
          }
        ]
      }
    })
  end
end
