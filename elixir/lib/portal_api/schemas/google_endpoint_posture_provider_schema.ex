defmodule PortalAPI.Schemas.GoogleEndpointPostureProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.GoogleEndpoint.PostureProvider,
             internal: [:error_email_count]}
    OpenApiSpex.schema(%{
      title: "GoogleEndpointPostureProvider",
      description: "Google Endpoint Management posture provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        account_id: %Schema{type: :string, format: :uuid},
        type: %Schema{type: :string, enum: ["google_endpoint"]},
        name: %Schema{type: :string},
        impersonation_email: %Schema{
          type: :string,
          description: "Workspace administrator the sync acts as, set by the Google sign-in that verified the provider"
        },
        domain: %Schema{type: :string, description: "Primary domain of the connected Google Workspace"},
        is_verified: %Schema{type: :boolean},
        is_disabled: %Schema{type: :boolean},
        disabled_reason: %Schema{type: :string, nullable: true},
        synced_at: %Schema{type: :string, format: :"date-time", nullable: true},
        errored_at: %Schema{type: :string, format: :"date-time", nullable: true},
        error_message: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :account_id,
        :disabled_reason,
        :domain,
        :error_message,
        :errored_at,
        :id,
        :impersonation_email,
        :inserted_at,
        :is_disabled,
        :is_verified,
        :name,
        :synced_at,
        :type,
        :updated_at
      ]
    })

    def map(%Portal.GoogleEndpoint.PostureProvider{posture_provider: %{name: name}}, _map), do: %{type: "google_endpoint", name: name}

  end

  defmodule UpdateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GoogleEndpointPostureProviderUpdateRequest",
      description:
        "PUT/PATCH body for updating a Google Endpoint posture provider. All fields are optional; " <>
          "omitted fields keep their current value.",
      type: :object,
      properties: %{
        google_endpoint_posture_provider: %Schema{
          type: :object,
          properties: %{
            name: %Schema{
              type: :string,
              minLength: 1,
              maxLength: 255,
              example: "Google Endpoint Management",
              description: "Name shown to admins, unique across the account's posture providers"
            },
            is_disabled: %Schema{
              type: :boolean,
              example: false,
              description:
                "Whether the provider is disabled. A provider can be enabled only while it is verified."
            }
          },
          additionalProperties: false
        }
      },
      required: [:google_endpoint_posture_provider]
    })
  end

  defmodule Response do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "GoogleEndpointPostureProviderResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.GoogleEndpointPostureProvider.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "GoogleEndpointPostureProviderListResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: PortalAPI.Schemas.GoogleEndpointPostureProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
