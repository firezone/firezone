defmodule PortalAPI.Schemas.SantaDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @not_null [:account_id, :id, :posture_provider_id, :santa_id, :synced_at]

    # Property types come from the Ecto schema; the field list is explicit so a
    # newly synced column is published only once it is added here.
    @fields [
      :account_id,
      :id,
      :santa_id,
      :posture_provider_id,
      :serial_number,
      :machine_model,
      :hostname,
      :os_version,
      :os_build,
      :os_type,
      :sip_status,
      :primary_user,
      :primary_user_locked,
      :primary_user_groups,
      :santa_version,
      :santanetd_version,
      :last_seen_client_mode,
      :last_sync_at,
      :rule_sync_at,
      :last_preflight_at,
      :last_preflight_ip,
      :tags,
      :tags_locked,
      :tags_truncated,
      :configured_client_mode,
      :temporary_monitor_mode_ends_at,
      :first_seen_at,
      :temporary_admin_mode_ends_at,
      :temporary_admin_mode_user,
      :synced_at,
      :inserted_at,
      :updated_at
    ]

    @properties Map.new(@fields, fn field ->
                  nullable = field not in @not_null

                  schema =
                    case Portal.Santa.Device.__schema__(:type, field) do
                      :binary_id ->
                        %Schema{type: :string, format: :uuid, nullable: nullable}

                      :string ->
                        %Schema{type: :string, nullable: nullable}

                      Portal.Types.IP ->
                        %Schema{type: :string, nullable: nullable}

                      :boolean ->
                        %Schema{type: :boolean, nullable: nullable}

                      :integer ->
                        %Schema{type: :integer, nullable: nullable}

                      :utc_datetime_usec ->
                        %Schema{type: :string, format: :"date-time", nullable: nullable}

                      {:array, :string} ->
                        %Schema{
                          type: :array,
                          items: %Schema{type: :string},
                          nullable: nullable
                        }
                    end

                  {field, schema}
                end)

    @derive {PortalAPI.JSON.Encoder, for: Portal.Santa.Device}
    OpenApiSpex.schema(%{
      title: "SantaDevice",
      description: "Santa host synced from North Pole Security Workshop",
      type: :object,
      properties: @properties,
      required: @fields
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SantaDeviceResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.SantaDevice.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "SantaDeviceListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.SantaDevice.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
