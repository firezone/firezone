defmodule PortalAPI.Schemas.EmailOTPAuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "EmailOTPAuthProvider",
      description: "Email OTP Auth Provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Provider ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{type: :string, description: "Provider name"},
        issuer: %Schema{type: :string, description: "Issuer"},
        context: %Schema{
          type: :string,
          description: "Context",
          enum: ["clients_and_portal", "clients_only", "portal_only"]
        },
        client_session_lifetime_secs: %Schema{
          type: :integer,
          nullable: true,
          description: "Client session lifetime in seconds. Null when the account default applies."
        },
        portal_session_lifetime_secs: %Schema{
          type: :integer,
          nullable: true,
          description: "Portal session lifetime in seconds. Null when the account default applies."
        },
        is_disabled: %Schema{type: :boolean, description: "Whether provider is disabled"},
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{type: :string, format: :"date-time", description: "Update timestamp"}
      },
      required: [
        :account_id,
        :client_session_lifetime_secs,
        :context,
        :id,
        :inserted_at,
        :is_disabled,
        :issuer,
        :name,
        :portal_session_lifetime_secs,
        :updated_at
      ],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "account_id" => "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
        "name" => "Email OTP",
        "issuer" => "firezone",
        "context" => "clients_and_portal",
        "client_session_lifetime_secs" => 604_800,
        "portal_session_lifetime_secs" => 28_800,
        "is_disabled" => false,
        "inserted_at" => "2025-01-01T00:00:00Z",
        "updated_at" => "2025-01-15T10:30:00Z"
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.EmailOTPAuthProvider

    OpenApiSpex.schema(%{
      title: "EmailOTPAuthProviderResponse",
      description: "Response schema for single Email OTP Auth Provider",
      type: :object,
      properties: %{
        data: EmailOTPAuthProvider.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.EmailOTPAuthProvider
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "EmailOTPAuthProviderListResponse",
      description: "Response schema for multiple Email OTP Auth Providers",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Email OTP Auth Provider details",
          type: :array,
          items: EmailOTPAuthProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
