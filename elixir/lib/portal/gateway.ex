defmodule Portal.Gateway do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          external_id: String.t(),
          name: String.t(),
          public_key: String.t(),
          psk_base: binary(),
          ipv4_address: Portal.IPv4Address.t(),
          ipv6_address: Portal.IPv6Address.t(),
          last_seen_user_agent: String.t(),
          last_seen_remote_ip: Portal.Types.IP.t(),
          last_seen_remote_ip_location_region: String.t(),
          last_seen_remote_ip_location_city: String.t(),
          last_seen_remote_ip_location_lat: float(),
          last_seen_remote_ip_location_lon: float(),
          last_seen_version: String.t(),
          last_seen_at: DateTime.t(),
          online?: boolean(),
          account_id: Ecto.UUID.t(),
          site_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "gateways" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :external_id, :string

    field :name, :string

    field :public_key, :string
    field :psk_base, :binary, read_after_writes: true

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Portal.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_version, :string
    field :last_seen_at, :utc_datetime_usec

    field :online?, :boolean, virtual: true
    field :latest_session, :any, virtual: true

    belongs_to :site, Portal.Site

    has_many :gateway_sessions, Portal.GatewaySession, references: :id
    has_one :ipv4_address, Portal.IPv4Address, references: :id
    has_one :ipv6_address, Portal.IPv6Address, references: :id

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> trim_change(:name)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name, name: :gateways_site_id_name_index)
    |> unique_constraint([:public_key])
    |> unique_constraint(:external_id)
    |> unique_constraint(:public_key, name: :gateways_account_id_public_key_index)
    |> assoc_constraint(:account)
    |> assoc_constraint(:site)
  end

  # Utility functions moved from Portal.Gateways

  def load_balance_gateways({_lat, _lon}, []) do
    nil
  end

  def load_balance_gateways({lat, lon}, gateways) when is_nil(lat) or is_nil(lon) do
    Enum.random(gateways)
  end

  def load_balance_gateways({lat, lon}, gateways) do
    gateways
    # Group gateways by their geographical location
    |> Enum.group_by(fn gateway ->
      session = gateway.latest_session
      {session && session.remote_ip_location_lat, session && session.remote_ip_location_lon}
    end)
    # Replace the location with the approximate distance to the client
    |> Enum.map(fn
      {{gateway_lat, gateway_lon}, gateway} when is_nil(gateway_lat) or is_nil(gateway_lon) ->
        {nil, gateway}

      {{gateway_lat, gateway_lon}, gateway} ->
        distance = Portal.Geo.distance({lat, lon}, {gateway_lat, gateway_lon})
        {distance, gateway}
    end)
    # Sort by the distance to the client
    |> Enum.sort_by(&elem(&1, 0))
    # Select all gateways in the nearest location
    |> List.first()
    |> elem(1)
    # Group nearest gateways by their version and only leave the one running the greatest one
    |> Enum.group_by(fn gateway ->
      session = gateway.latest_session
      session && session.version
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.at(0)
    |> elem(1)
    # From all nearest gateways of the latest version, select the one at random
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
