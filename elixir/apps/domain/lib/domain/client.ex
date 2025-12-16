defmodule Domain.Client do
  use Ecto.Schema
  import Ecto.Changeset
  import Domain.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          external_id: String.t(),
          name: String.t(),
          public_key: String.t(),
          psk_base: binary(),
          ipv4_address: Domain.IPv4Address.t(),
          ipv6_address: Domain.IPv6Address.t(),

          # TODO: Remove fields redundant with Subject.Context
          last_seen_user_agent: String.t(),
          last_seen_remote_ip: Domain.Types.IP.t(),
          last_seen_remote_ip_location_region: String.t(),
          last_seen_remote_ip_location_city: String.t(),
          last_seen_remote_ip_location_lat: float(),
          last_seen_remote_ip_location_lon: float(),
          last_seen_version: String.t(),
          last_seen_at: DateTime.t(),
          online?: boolean(),
          account_id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t(),
          device_serial: String.t() | nil,
          device_uuid: String.t() | nil,
          identifier_for_vendor: String.t() | nil,
          firebase_installation_id: String.t() | nil,
          verified_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "clients" do
    belongs_to :account, Domain.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :external_id, :string

    field :name, :string

    field :public_key, :string
    field :psk_base, :binary, read_after_writes: true

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Domain.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_version, :string
    field :last_seen_at, :utc_datetime_usec

    field :online?, :boolean, virtual: true

    belongs_to :actor, Domain.Actor

    has_one :ipv4_address, Domain.IPv4Address, references: :id
    has_one :ipv6_address, Domain.IPv6Address, references: :id

    # Hardware Identifiers
    field :device_serial, :string
    field :device_uuid, :string
    field :identifier_for_vendor, :string
    field :firebase_installation_id, :string

    # Verification
    field :verified_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> trim_change(~w[name external_id]a)
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> unique_constraint([:actor_id, :public_key],
      name: :clients_account_id_actor_id_public_key_index
    )
    |> unique_constraint([:actor_id, :external_id],
      name: :clients_account_id_actor_id_external_id_index
    )
  end
end
