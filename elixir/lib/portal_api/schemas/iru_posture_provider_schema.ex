defmodule PortalAPI.Schemas.IruPostureProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    @behaviour PortalAPI.Schema

    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IruPostureProvider",
      description: "Iru (formerly Kandji) posture provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        account_id: %Schema{type: :string, format: :uuid},
        type: %Schema{type: :string, enum: ["iru"]},
        name: %Schema{type: :string},
        subdomain: %Schema{type: :string},
        region: %Schema{type: :string, enum: ["us", "eu"]},
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
        :region,
        :subdomain,
        :synced_at,
        :type,
        :updated_at
      ]
    })

    @impl true
    def struct_module, do: Portal.Iru.PostureProvider

    @impl true
    def internal, do: [:error_email_count]

    @impl true
    def computed, do: [:type, :name]

    @impl true
    def value(:type, %Portal.Iru.PostureProvider{}), do: "iru"
    def value(:name, %Portal.Iru.PostureProvider{posture_provider: %{name: name}}), do: name
    def value(field, provider), do: Map.fetch!(provider, field)
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IruPostureProviderResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.IruPostureProvider.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "IruPostureProviderListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.IruPostureProvider.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
