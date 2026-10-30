defmodule Portal.Sophos.Device do
  @moduledoc """
  A Sophos Central endpoint, as `GET /endpoint/v1/endpoints?view=full` reports it.

  Nested objects with a fixed set of scalars are flattened into columns;
  repeated or open-ended ones stay JSON so nothing the API reports is dropped.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sophos_devices" do
    belongs_to :account, Portal.Account, primary_key: true
    field :sophos_id, :string, primary_key: true
    belongs_to :posture_provider, Portal.PostureProvider

    field :type, :string
    field :sophos_tenant_id, :string
    field :hostname, :string

    field :health_overall, :string
    field :health_threats_status, :string
    field :health_services_status, :string
    field :health_service_details, {:array, :map}

    field :os_is_server, :boolean
    field :os_platform, :string
    field :os_name, :string
    field :os_major_version, :integer
    field :os_minor_version, :integer
    field :os_build, :integer

    field :ipv4_addresses, {:array, :string}
    field :ipv6_addresses, {:array, :string}
    field :mac_addresses, {:array, :string}

    field :group_id, :string
    field :group_name, :string
    field :group_hierarchy, {:array, :map}

    field :associated_person_id, :string
    field :associated_person_name, :string
    field :associated_person_via_login, :string

    field :tamper_protection_supported, :boolean
    field :tamper_protection_enabled, :boolean
    field :assigned_products, {:array, :map}
    field :packages, :map
    field :device_software, :map

    field :last_seen_at, :utc_datetime_usec
    field :last_os_update_at, :utc_datetime_usec
    field :last_agent_update_at, :utc_datetime_usec
    field :serial_number, :string

    field :encryption_overall_status, :string
    field :encryption_volumes, {:array, :map}
    field :lockdown_status, :string
    field :tags, {:array, :map}
    field :online, :boolean
    field :cloud_provider, :string
    field :cloud_instance_id, :string
    field :isolation_status, :string
    field :isolation_admin_isolated, :boolean
    field :isolation_self_isolated, :boolean
    field :cloned, :boolean

    field :synced_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, __schema__(:fields) -- [:inserted_at, :updated_at])
    |> changeset()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :posture_provider_id, :sophos_id, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
  end
end
