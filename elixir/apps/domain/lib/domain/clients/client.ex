defmodule Domain.Clients.Client do
  use Domain, :schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          external_id: String.t(),
          name: String.t(),
          public_key: String.t(),
          psk_base: binary(),
          ipv4: Domain.Types.IP.t(),
          ipv6: Domain.Types.IP.t(),

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
          verified_by: :system | :actor | :identity | nil,
          verified_by_subject: map() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "clients" do
    field :external_id, :string

    field :name, :string

    field :public_key, :string
    field :psk_base, :binary, read_after_writes: true

    field :ipv4, Domain.Types.IP
    field :ipv6, Domain.Types.IP

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Domain.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_version, :string
    field :last_seen_at, :utc_datetime_usec

    field :online?, :boolean, virtual: true

    belongs_to :account, Domain.Accounts.Account
    belongs_to :actor, Domain.Actors.Actor

    # Hardware Identifiers
    field :device_serial, :string
    field :device_uuid, :string
    field :identifier_for_vendor, :string
    field :firebase_installation_id, :string

    # Verification
    field :verified_at, :utc_datetime_usec
    field :verified_by, Ecto.Enum, values: [:system, :actor]
    field :verified_by_subject, :map

    timestamps()
  end
end
