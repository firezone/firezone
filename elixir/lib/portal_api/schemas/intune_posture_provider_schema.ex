defmodule PortalAPI.Schemas.IntunePostureProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    @behaviour PortalAPI.Schema

    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntunePostureProvider",
      description: "Microsoft Intune posture provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        account_id: %Schema{type: :string, format: :uuid},
        type: %Schema{type: :string, enum: ["intune"]},
        name: %Schema{type: :string},
        tenant_id: %Schema{type: :string},
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
        :error_message,
        :errored_at,
        :id,
        :inserted_at,
        :is_disabled,
        :is_verified,
        :name,
        :synced_at,
        :tenant_id,
        :type,
        :updated_at
      ]
    })

    @impl true
    def struct_module, do: Portal.Intune.PostureProvider

    @impl true
    def internal, do: [:error_email_count]

    @impl true
    def computed, do: [:type, :name]

    @impl true
    def value(:type, %Portal.Intune.PostureProvider{}), do: "intune"
    def value(:name, %Portal.Intune.PostureProvider{posture_provider: %{name: name}}), do: name
    def value(field, provider), do: Map.fetch!(provider, field)
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntunePostureProviderResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.IntunePostureProvider.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "IntunePostureProviderListResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: PortalAPI.Schemas.IntunePostureProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
