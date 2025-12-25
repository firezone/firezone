defmodule PortalAPI.Schemas.EntraAuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "EntraAuthProvider",
      description: "Entra Auth Provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Provider ID"},
        account_id: %Schema{type: :string, description: "Account ID"},
        name: %Schema{type: :string, description: "Provider name"},
        issuer: %Schema{type: :string, description: "Issuer"},
        context: %Schema{
          type: :string,
          description: "Context",
          enum: ["clients_and_portal", "clients_only", "portal_only"]
        },
        client_session_lifetime_secs: %Schema{
          type: :integer,
          description: "Client session lifetime in seconds"
        },
        portal_session_lifetime_secs: %Schema{
          type: :integer,
          description: "Portal session lifetime in seconds"
        },
        is_disabled: %Schema{type: :boolean, description: "Whether provider is disabled"},
        is_default: %Schema{type: :boolean, description: "Whether provider is default"},
        inserted_at: %Schema{type: :string, format: :datetime, description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :datetime, description: "Update timestamp"}
      },
      required: [:id, :name],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Entra",
        "issuer" => "https://login.microsoftonline.com/tenant-id/v2.0"
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.EntraAuthProvider

    OpenApiSpex.schema(%{
      title: "EntraAuthProviderResponse",
      description: "Response schema for single Entra Auth Provider",
      type: :object,
      properties: %{
        data: EntraAuthProvider.Schema
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
    alias PortalAPI.Schemas.EntraAuthProvider

    OpenApiSpex.schema(%{
      title: "EntraAuthProviderListResponse",
      description: "Response schema for multiple Entra Auth Providers",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Entra Auth Provider details",
          type: :array,
          items: EntraAuthProvider.Schema
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
