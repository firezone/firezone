defmodule Portal.Device do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  # Reserved address ranges that must not overlap with user-configurable resources or DNS.
  @reserved_ipv4_cidr %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 10}
  @reserved_ipv6_cidr %Postgrex.INET{address: {64_768, 8_225, 4_369, 0, 0, 0, 0, 0}, netmask: 48}

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  # Columns rewritten by the connect flush; WAL consumers skip device updates
  # that touch nothing else so connects don't flood audit logs and broadcasts.
  @latest_session_columns ~w[
    public_key
    last_seen_user_agent
    last_seen_remote_ip
    last_seen_remote_ip_location_region
    last_seen_remote_ip_location_city
    last_seen_remote_ip_location_lat
    last_seen_remote_ip_location_lon
    last_seen_version
    last_seen_at
    client_token_id
    gateway_token_id
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          type: :client | :gateway,
          # nil for pre-created gateways until they first connect and report one
          firezone_id: String.t() | nil,
          name: String.t(),
          psk_base: binary(),
          ipv4: Postgrex.INET.t(),
          ipv6: Postgrex.INET.t(),
          online?: boolean(),
          firezone_id_merged?: boolean(),
          public_key: String.t() | nil,
          last_seen_user_agent: String.t() | nil,
          last_seen_remote_ip: Postgrex.INET.t() | nil,
          last_seen_remote_ip_location_region: String.t() | nil,
          last_seen_remote_ip_location_city: String.t() | nil,
          last_seen_remote_ip_location_lat: float() | nil,
          last_seen_remote_ip_location_lon: float() | nil,
          last_seen_version: String.t() | nil,
          last_seen_at: DateTime.t() | nil,
          client_token_id: Ecto.UUID.t() | nil,
          gateway_token_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t() | nil,
          site_id: Ecto.UUID.t() | nil,
          device_serial: String.t() | nil,
          device_uuid: String.t() | nil,
          identifier_for_vendor: String.t() | nil,
          firebase_installation_id: String.t() | nil,
          hostname: String.t() | nil,
          last_attested_device_serial: String.t() | nil,
          last_attested_device_uuid: String.t() | nil,
          last_attested_mdm_device_id: String.t() | nil,
          last_attested_cert_serial: String.t() | nil,
          last_attested_cert_fingerprint: String.t() | nil,
          verified_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "devices" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :type, Ecto.Enum, values: [:client, :gateway]

    field :firezone_id, :string
    field :name, :string
    field :psk_base, :binary, read_after_writes: true, redact: true

    field :ipv4, Portal.Types.IP, read_after_writes: true
    field :ipv6, Portal.Types.IP, read_after_writes: true

    # Client-only
    belongs_to :actor, Portal.Actor
    field :device_serial, :string
    field :device_uuid, :string
    field :identifier_for_vendor, :string
    field :firebase_installation_id, :string
    field :hostname, :string

    # Device trust. Enforced client-only today, but gateways may adopt
    # cert-based verification too, hence no client_ prefix on the cert columns.
    field :last_attested_device_serial, :string
    field :last_attested_device_uuid, :string
    field :last_attested_mdm_device_id, :string
    field :last_attested_cert_serial, :string
    field :last_attested_cert_fingerprint, :string
    field :verified_at, :utc_datetime_usec

    # Gateway-only
    belongs_to :site, Portal.Site

    has_many :gateway_tokens, Portal.GatewayToken,
      foreign_key: :device_id,
      references: :id

    # Latest-session fields, written by the connect flush. The flush probes
    # the token columns' referents and fails entries whose token was deleted;
    # the FKs nilify on token delete so the columns never dangle.
    field :public_key, :string
    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Portal.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_version, :string
    field :last_seen_at, :utc_datetime_usec
    field :client_token_id, :binary_id
    field :gateway_token_id, :binary_id

    # Virtual fields
    field :online?, :boolean, virtual: true, default: false

    # Set when this connect adopted a new firezone_id (attested-first merge).
    # The session flush persists firezone_id only for merged connects, so the
    # steady state adds no conflict-probe query to the flush.
    field :firezone_id_merged?, :boolean, virtual: true, default: false

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> trim_change(~w[name firezone_id hostname]a)
    |> normalize_hostname()
    |> validate_required([:type, :name, :firezone_id])
    |> validate_inclusion(:type, [:client, :gateway])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:firezone_id, max: 255)
    |> validate_length(:hostname, min: 3, max: 255)
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:site)
    |> validate_type_fields()
    |> check_constraint(:type, name: :devices_type_check)
    |> check_constraint(:actor_id, name: :device_type_client_fields)
    |> check_constraint(:site_id, name: :device_type_gateway_fields)
    |> unique_firezone_id_constraint()
    |> unique_constraint(:ipv4, name: :devices_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :devices_account_id_ipv6_index)
    |> unique_constraint(:hostname, name: :devices_account_id_hostname_index)
    |> check_constraint(:hostname, name: :devices_hostname_length)
  end

  def reserved_ipv4_cidr, do: @reserved_ipv4_cidr
  def reserved_ipv6_cidr, do: @reserved_ipv6_cidr

  def latest_session_columns, do: @latest_session_columns

  defp validate_type_fields(changeset) do
    case get_field(changeset, :type) do
      :client ->
        changeset
        |> validate_required([:actor_id])
        |> validate_length(:device_serial, max: 255)
        |> validate_length(:device_uuid, max: 255)
        |> validate_length(:identifier_for_vendor, max: 255)
        |> validate_length(:firebase_installation_id, max: 255)
        |> validate_length(:last_attested_device_serial, max: 255)
        |> validate_length(:last_attested_device_uuid, max: 255)
        |> validate_length(:last_attested_mdm_device_id, max: 255)
        |> validate_length(:last_attested_cert_serial, max: 255)
        |> validate_length(:last_attested_cert_fingerprint, max: 255)
        |> unique_constraint(:last_attested_device_serial,
          name: :devices_account_id_actor_id_last_attested_device_serial_index
        )
        |> unique_constraint(:last_attested_device_uuid,
          name: :devices_account_id_actor_id_last_attested_device_uuid_index
        )
        |> unique_constraint(:last_attested_mdm_device_id,
          name: :devices_account_id_actor_id_last_attested_mdm_device_id_index
        )

      :gateway ->
        changeset
        |> validate_required([:site_id])
        |> validate_gateway_verification()

      _ ->
        changeset
    end
  end

  defp validate_gateway_verification(changeset) do
    if is_nil(get_field(changeset, :verified_at)) do
      changeset
    else
      add_error(changeset, :verified_at, "can only be set for client devices")
    end
  end

  # Empty / whitespace-only inputs collapse to nil so users can clear the field by
  # sending "" rather than having to send `null`. Casing is preserved — the underlying
  # column is `citext`, so equality/uniqueness already fold case at the DB layer.
  defp normalize_hostname(changeset) do
    update_change(changeset, :hostname, fn
      nil -> nil
      "" -> nil
      hostname -> hostname
    end)
  end

  defp unique_firezone_id_constraint(changeset) do
    case get_field(changeset, :type) do
      :client ->
        unique_constraint(changeset, :firezone_id,
          name: :devices_account_id_actor_id_firezone_id_index
        )

      :gateway ->
        unique_constraint(changeset, :firezone_id,
          name: :devices_account_id_site_id_firezone_id_index
        )

      _ ->
        changeset
    end
  end

  # Gateway device helpers

  def load_balance_gateways({_lat, _lon}, []) do
    nil
  end

  def load_balance_gateways({lat, lon}, gateways) when is_nil(lat) or is_nil(lon) do
    Enum.random(gateways)
  end

  def load_balance_gateways({lat, lon}, gateways) do
    gateways
    |> Enum.group_by(fn gateway ->
      {gateway.last_seen_remote_ip_location_lat, gateway.last_seen_remote_ip_location_lon}
    end)
    |> Enum.map(fn
      {{gateway_lat, gateway_lon}, gateway} when is_nil(gateway_lat) or is_nil(gateway_lon) ->
        {nil, gateway}

      {{gateway_lat, gateway_lon}, gateway} ->
        distance = Portal.Geo.distance({lat, lon}, {gateway_lat, gateway_lon})
        {distance, gateway}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> List.first()
    |> elem(1)
    |> Enum.group_by(& &1.last_seen_version)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.at(0)
    |> elem(1)
    |> Enum.random()
  end

  def load_balance_gateways({lat, lon}, gateways, preferred_gateway_ids) do
    gateways
    |> Enum.filter(&(&1.id in preferred_gateway_ids))
    |> case do
      [] -> load_balance_gateways({lat, lon}, gateways)
      preferred_gateways -> load_balance_gateways({lat, lon}, preferred_gateways)
    end
  end

  def gateway_outdated?(gateway) do
    latest_release = Portal.ComponentVersions.gateway_version()
    version = gateway.last_seen_version

    if version do
      case Version.compare(version, latest_release) do
        :lt -> true
        _ -> false
      end
    else
      false
    end
  end
end
