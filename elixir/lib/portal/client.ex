defmodule Portal.Client do
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
          psk_base: binary(),
          ipv4_address: Portal.IPv4Address.t(),
          ipv6_address: Portal.IPv6Address.t(),
          online?: boolean(),
          latest_session: Portal.ClientSession.t() | nil,
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
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    # TODO: remove last_seen_* fields in migration

    field :external_id, :string
    field :name, :string
    field :psk_base, :binary, read_after_writes: true
    field :latest_session, :any, virtual: true
    field :online?, :boolean, virtual: true

    belongs_to :actor, Portal.Actor

    has_one :ipv4_address, Portal.IPv4Address, references: :id
    has_one :ipv6_address, Portal.IPv6Address, references: :id

    has_many :client_sessions, Portal.ClientSession, references: :id

    # Hardware Identifiers
    field :device_serial, :string
    field :device_uuid, :string
    field :identifier_for_vendor, :string
    field :firebase_installation_id, :string

    # Verification
    field :verified_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> trim_change(~w[name external_id]a)
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> unique_constraint([:actor_id, :external_id],
      name: :clients_account_id_actor_id_external_id_index
    )
  end
end
