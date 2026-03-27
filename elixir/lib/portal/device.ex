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

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          type: :client | :gateway,
          firezone_id: String.t(),
          name: String.t(),
          psk_base: binary(),
          ipv4: Postgrex.INET.t(),
          ipv6: Postgrex.INET.t(),
          online?: boolean(),
          latest_session: any() | nil,
          latest_session_inserted_at: DateTime.t() | nil,
          latest_session_version: String.t() | nil,
          latest_session_user_agent: String.t() | nil,
          account_id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t() | nil,
          site_id: Ecto.UUID.t() | nil,
          device_serial: String.t() | nil,
          device_uuid: String.t() | nil,
          identifier_for_vendor: String.t() | nil,
          firebase_installation_id: String.t() | nil,
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
    field :psk_base, :binary, read_after_writes: true

    field :ipv4, Portal.Types.IP, read_after_writes: true
    field :ipv6, Portal.Types.IP, read_after_writes: true

    # Client-only
    belongs_to :actor, Portal.Actor
    field :device_serial, :string
    field :device_uuid, :string
    field :identifier_for_vendor, :string
    field :firebase_installation_id, :string
    field :verified_at, :utc_datetime_usec

    # Gateway-only
    belongs_to :site, Portal.Site

    has_many :client_sessions, Portal.ClientSession,
      foreign_key: :device_id,
      references: :id

    has_many :gateway_sessions, Portal.GatewaySession,
      foreign_key: :device_id,
      references: :id

    # Virtual fields
    field :online?, :boolean, virtual: true, default: false
    field :latest_session, :any, virtual: true
    field :latest_session_inserted_at, :utc_datetime_usec, virtual: true
    field :latest_session_version, :string, virtual: true
    field :latest_session_user_agent, :string, virtual: true

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> trim_change(~w[name firezone_id]a)
    |> validate_required([:type, :name, :firezone_id])
    |> validate_inclusion(:type, [:client, :gateway])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:firezone_id, max: 255)
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
  end

  def reserved_ipv4_cidr, do: @reserved_ipv4_cidr
  def reserved_ipv6_cidr, do: @reserved_ipv6_cidr

  defp validate_type_fields(changeset) do
    case get_field(changeset, :type) do
      :client ->
        changeset
        |> validate_required([:actor_id])
        |> validate_length(:device_serial, max: 255)
        |> validate_length(:device_uuid, max: 255)
        |> validate_length(:identifier_for_vendor, max: 255)
        |> validate_length(:firebase_installation_id, max: 255)

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
      session = gateway.latest_session
      {session && session.remote_ip_location_lat, session && session.remote_ip_location_lon}
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
    |> Enum.group_by(fn gateway ->
      session = gateway.latest_session
      session && session.version
    end)
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
    version = gateway.latest_session && gateway.latest_session.version

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
