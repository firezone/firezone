defmodule PortalAPI.Schemas.SantaPostureProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    @behaviour PortalAPI.Schema

    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SantaPostureProvider",
      description: "Santa posture provider backed by North Pole Security Workshop",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        account_id: %Schema{type: :string, format: :uuid},
        type: %Schema{type: :string, enum: ["santa"]},
        name: %Schema{type: :string},
        api_url: %Schema{type: :string, format: :uri},
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
        :api_url,
        :disabled_reason,
        :error_message,
        :errored_at,
        :id,
        :inserted_at,
        :is_disabled,
        :is_verified,
        :name,
        :synced_at,
        :type,
        :updated_at
      ]
    })

    @impl true
    def struct_module, do: Portal.Santa.PostureProvider

    @impl true
    def internal, do: [:error_email_count]

    @impl true
    def computed, do: [:type, :name]

    @impl true
    def value(:type, %Portal.Santa.PostureProvider{}), do: "santa"
    def value(:name, %Portal.Santa.PostureProvider{posture_provider: %{name: name}}), do: name
    def value(field, provider), do: Map.fetch!(provider, field)
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SantaPostureProviderResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.SantaPostureProvider.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "SantaPostureProviderListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.SantaPostureProvider.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
