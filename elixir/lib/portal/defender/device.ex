defmodule Portal.Defender.Device do
  @moduledoc """
  A single Microsoft Defender for Endpoint `machine`.

  Every property the machines endpoint reports gets a column, including the
  members of `vm_metadata`, which are flattened behind a `vm_` prefix.
  `ipAddresses` is the one property whose members are objects rather than
  strings, so it is stored as JSON rather than flattened.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "defender_devices" do
    belongs_to :account, Portal.Account, primary_key: true

    # Defender's machine id, unique per tenant and stable for the life of the
    # onboarding, so it is the key rather than an id of our own.
    field :defender_id, :string, primary_key: true

    belongs_to :posture_provider, Portal.PostureProvider

    field :computer_dns_name, :string
    field :entra_device_id, :string
    field :entra_joined, :boolean
    field :machine_tags, {:array, :string}

    field :os_platform, :string

    # The Windows feature release the build belongs to, such as "1709". Named
    # `version` on the machine entity, which has no other OS version property.
    field :version, :string
    field :os_build, :integer
    field :os_processor, :string
    field :os_architecture, :string

    field :last_ip_address, Portal.Types.IP
    field :last_external_ip_address, Portal.Types.IP

    field :agent_version, :string
    field :health_status, :string
    field :onboarding_status, :string
    field :managed_by, :string
    field :managed_by_status, :string

    field :risk_score, :string
    field :exposure_level, :string
    field :device_value, :string

    field :rbac_group_id, :integer
    field :rbac_group_name, :string

    field :is_potential_duplication, :boolean
    field :merged_into_machine_id, :string
    field :is_excluded, :boolean
    field :exclusion_reason, :string

    field :vm_id, :string
    field :vm_cloud_provider, :string
    field :vm_resource_id, :string
    field :vm_subscription_id, :string

    field :ip_addresses, {:array, :map}

    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
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
    |> validate_required([:account_id, :posture_provider_id, :defender_id, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
  end
end
