defmodule PortalAPI.Schemas.SantaPostureProvider do
  alias OpenApiSpex.Schema
  require Protocol

  Protocol.derive(PortalAPI.JSON.Encoder, Portal.Santa.PostureProvider,
    except: [:error_email_count],
    mapper: &PortalAPI.Schemas.SantaPostureProvider.map/2
  )

  def map(%Portal.Santa.PostureProvider{posture_provider: %{name: name}}, _map), do: %{type: "santa", name: name}

  defmodule Schema do
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
