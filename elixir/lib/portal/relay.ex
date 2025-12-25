defmodule Portal.Relay do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "relays" do
    field :name, :string

    field :ipv4, Portal.Types.IP
    field :ipv6, Portal.Types.IP

    field :port, :integer, default: 3478

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Portal.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_version, :string
    field :last_seen_at, :utc_datetime_usec

    field :stamp_secret, :string, virtual: true

    field :online?, :boolean, virtual: true

    timestamps()
  end

  def changeset(relay \\ %__MODULE__{}, attrs) do
    relay
    |> cast(attrs, [
      :name,
      :ipv4,
      :ipv6,
      :port,
      :last_seen_user_agent,
      :last_seen_remote_ip,
      :last_seen_remote_ip_location_region,
      :last_seen_remote_ip_location_city,
      :last_seen_remote_ip_location_lat,
      :last_seen_remote_ip_location_lon,
      :last_seen_version,
      :last_seen_at
    ])
    |> validate_required_one_of(~w[ipv4 ipv6]a)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> unique_constraint(:ipv4, name: :relays_unique_address_index)
    |> unique_constraint(:ipv6, name: :relays_unique_address_index)
    |> unique_constraint(:port, name: :relays_unique_address_index)
    |> unique_constraint(:ipv4, name: :global_relays_unique_address_index)
    |> unique_constraint(:ipv6, name: :global_relays_unique_address_index)
    |> unique_constraint(:port, name: :global_relays_unique_address_index)
  end
end
