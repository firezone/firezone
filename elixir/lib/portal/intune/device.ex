defmodule Portal.Intune.Device do
  @moduledoc """
  A single Microsoft Graph `managedDevice`.

  Every property of the v1.0 resource gets a column, including the members of
  the two complex properties, which are flattened behind `config_manager_` and
  `attestation_` prefixes. `deviceActionResults` is the one collection-valued
  property, so it is stored as JSON rather than flattened.

  The two exceptions are `@odata.type`, which is a constant, and
  `activationLockBypassCode`, which defeats Apple Activation Lock and is
  deliberately never stored.

  Seven properties are always null: Graph withholds them from collection
  queries, and `$select` does not recover them even for a single device.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "intune_devices" do
    belongs_to :account, Portal.Account, primary_key: true

    # Graph's managedDevice id, unique per tenant and stable for the life of the
    # enrollment, so it is the key rather than an id of our own.
    field :intune_id, :string, primary_key: true

    belongs_to :posture_provider, Portal.PostureProvider

    field :device_name, :string
    field :managed_device_name, :string
    field :serial_number, :string
    field :entra_device_id, :string
    field :enrollment_profile_name, :string
    field :device_category_display_name, :string

    field :user_id, :string
    field :user_principal_name, :string
    field :user_display_name, :string
    field :email_address, :string

    field :operating_system, :string
    field :os_version, :string
    field :model, :string
    field :manufacturer, :string
    field :imei, :string
    field :meid, :string
    field :iccid, :string
    field :udid, :string
    field :phone_number, :string
    field :subscriber_carrier, :string
    field :wifi_mac_address, :string
    field :ethernet_mac_address, :string
    field :android_security_patch_level, :date
    field :total_storage_space_bytes, :integer
    field :free_storage_space_bytes, :integer
    field :physical_memory_bytes, :integer

    field :compliance_state, :string
    field :management_state, :string
    field :management_agent, :string
    field :managed_device_owner_type, :string
    field :device_enrollment_type, :string
    field :device_registration_state, :string
    field :partner_reported_threat_state, :string
    field :jail_broken, :boolean
    field :is_encrypted, :boolean
    field :is_supervised, :boolean
    field :entra_registered, :boolean
    field :require_user_enrollment_approval, :boolean
    field :notes, :string

    field :eas_activated, :boolean
    field :eas_device_id, :string
    field :eas_activated_at, :utc_datetime_usec
    field :exchange_access_state, :string
    field :exchange_access_state_reason, :string
    field :exchange_last_successful_sync_at, :utc_datetime_usec

    field :config_manager_inventory, :boolean
    field :config_manager_modern_apps, :boolean
    field :config_manager_resource_access, :boolean
    field :config_manager_device_configuration, :boolean
    field :config_manager_compliance_policy, :boolean
    field :config_manager_windows_update_for_business, :boolean

    field :attestation_last_update_date_time, :string
    field :attestation_content_namespace_url, :string
    field :attestation_status, :string
    field :attestation_content_version, :string
    field :attestation_issued_at, :utc_datetime_usec
    field :attestation_identity_key, :string
    field :attestation_reset_count, :integer
    field :attestation_restart_count, :integer
    field :attestation_data_execution_policy_enabled, :boolean
    field :attestation_bit_locker_enabled, :boolean
    field :attestation_boot_manager_version, :string
    field :attestation_code_integrity_check_version, :string
    field :attestation_secure_boot, :boolean
    field :attestation_boot_debugging, :boolean
    field :attestation_operating_system_kernel_debugging, :boolean
    field :attestation_code_integrity, :boolean
    field :attestation_test_signing, :boolean
    field :attestation_safe_mode, :boolean
    field :attestation_windows_pe, :boolean
    field :attestation_early_launch_anti_malware_driver_protection, :boolean
    field :attestation_virtual_secure_mode, :boolean
    field :attestation_pcr_hash_algorithm, :string
    field :attestation_boot_app_security_version, :string
    field :attestation_boot_manager_security_version, :string
    field :attestation_tpm_version, :string
    field :attestation_pcr0, :string
    field :attestation_secure_boot_config_policy_fingerprint, :string
    field :attestation_code_integrity_policy, :string
    field :attestation_boot_revision_list_info, :string
    field :attestation_operating_system_rev_list_info, :string
    field :attestation_health_status_mismatch_info, :string
    field :attestation_supported, :boolean

    field :device_action_results, {:array, :map}

    field :enrolled_at, :utc_datetime_usec
    field :last_sync_at, :utc_datetime_usec
    field :compliance_grace_period_expiration_at, :utc_datetime_usec
    field :management_certificate_expires_at, :utc_datetime_usec
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
    |> validate_required([:account_id, :posture_provider_id, :intune_id, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
  end
end
