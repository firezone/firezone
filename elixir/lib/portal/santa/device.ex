defmodule Portal.Santa.Device do
  @moduledoc """
  A Santa host synchronized from North Pole Security Workshop's `ListHosts` API.

  Workshop calls the remote identifier `uuid`, although Santa permits a custom
  machine identifier that is not a UUID. It is stored as `santa_id` and scoped
  to its posture provider because Workshop does not guarantee that reported
  machine IDs are unique across tenants.

  This schema mirrors `workshop.v1.Host`, which is shared by macOS and Linux
  inventory. Workshop's platform telemetry schemas describe events emitted by
  these hosts and are intentionally not mixed into this inventory record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "santa_devices" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true
    field :santa_id, :string
    belongs_to :posture_provider, Portal.PostureProvider

    field :serial_number, :string
    field :machine_model, :string
    field :hostname, :string
    field :os_version, :string
    field :os_build, :string
    field :os_type, :string
    field :sip_status, :integer
    field :primary_user, :string
    field :primary_user_locked, :boolean
    field :primary_user_groups, {:array, :string}
    field :santa_version, :string
    field :santanetd_version, :string
    field :last_seen_client_mode, :string
    field :last_sync_at, :utc_datetime_usec
    field :rule_sync_at, :utc_datetime_usec
    field :last_preflight_at, :utc_datetime_usec
    field :last_preflight_ip, Portal.Types.IP
    field :tags, {:array, :string}
    field :tags_locked, :boolean
    field :tags_truncated, :boolean
    field :configured_client_mode, :string
    field :temporary_monitor_mode_ends_at, :utc_datetime_usec
    field :first_seen_at, :utc_datetime_usec
    field :temporary_admin_mode_ends_at, :utc_datetime_usec
    field :temporary_admin_mode_user, :string
    field :synced_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> changeset()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :posture_provider_id, :santa_id, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
  end
end
