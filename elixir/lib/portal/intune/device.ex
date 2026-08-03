defmodule Portal.Intune.Device do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "intune_devices" do
    belongs_to :account, Portal.Account
    belongs_to :device_integration, Portal.Intune.Integration
    belongs_to :device, Portal.Device

    field :intune_id, :string
    field :device_name, :string
    field :managed_device_name, :string
    field :serial_number, :string
    field :entra_device_id, :string

    field :user_id, :string
    field :user_principal_name, :string
    field :user_display_name, :string
    field :email_address, :string

    field :operating_system, :string
    field :os_version, :string
    field :model, :string
    field :manufacturer, :string

    field :compliance_state, :string
    field :management_agent, :string
    field :managed_device_owner_type, :string
    field :device_enrollment_type, :string
    field :device_registration_state, :string
    field :partner_reported_threat_state, :string
    field :jail_broken, :string
    field :is_encrypted, :boolean
    field :is_supervised, :boolean

    field :enrolled_at, :utc_datetime_usec
    field :last_sync_at, :utc_datetime_usec
    field :compliance_grace_period_expiration_at, :utc_datetime_usec
    field :synced_at, :utc_datetime_usec
    field :attributes, :map, default: %{}

    timestamps()
  end

  @fields ~w[
    account_id device_integration_id device_id intune_id device_name managed_device_name
    serial_number entra_device_id user_id user_principal_name user_display_name email_address
    operating_system os_version model manufacturer compliance_state management_agent
    managed_device_owner_type device_enrollment_type device_registration_state
    partner_reported_threat_state jail_broken is_encrypted is_supervised enrolled_at
    last_sync_at compliance_grace_period_expiration_at synced_at attributes
  ]a

  def changeset(device, attrs) do
    device
    |> cast(attrs, @fields)
    |> validate_required([:account_id, :device_integration_id, :intune_id, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:device_integration)
    |> assoc_constraint(:device)
  end
end
