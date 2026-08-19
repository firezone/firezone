defmodule Portal.Iru.Device do
  @moduledoc """
  A single device in an Iru (formerly Kandji) tenant.

  Iru spreads one device over several endpoints, so a row is the merge of the
  `/api/v1/devices` record with the Prism categories that report one row per
  device: device information, FileVault, application firewall, Gatekeeper and
  XProtect, startup settings, and activation lock. Each of those carries its own
  `last_collected_at`, kept here as a `*_collected_at` column, because a device
  can report one category long after another.

  Prism categories that report one row per item rather than per device
  (applications, certificates, profiles, local users, extensions) are not
  flattened here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "iru_devices" do
    belongs_to :account, Portal.Account, primary_key: true

    # Iru's device_id, unique per tenant and stable for the life of the
    # enrollment, so it is the key rather than an id of our own.
    field :iru_id, :string, primary_key: true

    belongs_to :posture_provider, Portal.PostureProvider

    field :device_name, :string
    field :model, :string
    field :serial_number, :string
    field :platform, :string
    field :os_version, :string
    field :supplemental_build_version, :string
    field :supplemental_os_version_extra, :string
    field :last_check_in_at, :utc_datetime_usec

    field :user_id, :string
    field :user_name, :string
    field :user_email, :string
    field :user_is_archived, :boolean

    field :asset_tag, :string
    field :blueprint_id, :string
    field :blueprint_name, :string
    field :mdm_enabled, :boolean
    field :agent_installed, :boolean
    field :agent_version, :string
    field :is_missing, :boolean
    field :is_removed, :boolean
    field :first_enrolled_at, :utc_datetime_usec
    field :last_enrolled_at, :utc_datetime_usec
    field :lost_mode_status, :string
    field :tags, {:array, :string}

    field :device_family, :string
    field :device_capacity_gb, :float
    field :host_name, :string
    field :local_hostname, :string
    field :apple_silicon, :boolean
    field :model_name, :string
    field :model_identifier, :string
    field :shared_ipad, :boolean
    field :cellular_technology, :string
    field :data_roaming, :boolean
    field :hotspot, :boolean
    field :os_build, :string
    field :os_name, :string
    field :display_os_version, :string
    field :inventory_collected_at, :utc_datetime_usec

    field :filevault_enabled, :boolean
    field :filevault_key_type, :string
    field :filevault_key_escrowed, :boolean
    field :filevault_regeneration_needed, :boolean
    field :filevault_key_rotation_scheduled_at, :utc_datetime_usec
    field :filevault_collected_at, :utc_datetime_usec

    field :firewall_enabled, :boolean
    field :firewall_block_all_incoming, :boolean
    field :firewall_logging, :boolean
    field :firewall_logging_option, :string
    field :firewall_stealth_mode, :boolean
    field :firewall_version, :string
    field :firewall_allow_signed_applications, :boolean
    field :firewall_unloading, :boolean
    field :firewall_collected_at, :utc_datetime_usec

    field :gatekeeper_enabled, :boolean
    field :gatekeeper_trusted_developers, :boolean
    field :gatekeeper_version, :string
    field :gatekeeper_opaque_version, :string
    field :xprotect_version, :string
    field :malware_removal_tool_version, :string
    field :gatekeeper_collected_at, :utc_datetime_usec

    field :sip_enabled, :boolean
    field :ssv_enabled, :boolean
    field :bootstrap_token_auth, :boolean
    field :bootstrap_token_escrowed, :boolean
    field :kext_requires_bootstrap_token, :boolean
    field :software_update_requires_bootstrap_token, :boolean
    field :external_boot_level, :string
    field :secure_boot_level, :string
    field :any_signed_os, :boolean
    field :mdm_manages_kext, :boolean
    field :user_manages_kext, :boolean
    field :startup_settings_collected_at, :utc_datetime_usec

    field :activation_lock_supported, :boolean
    field :activation_lock_allowed_while_supervised, :boolean
    field :device_activation_lock_enabled, :boolean
    field :user_activation_lock_enabled, :boolean
    field :activation_lock_bypass_code_failed, :boolean
    field :activation_lock_collected_at, :utc_datetime_usec

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
    |> validate_required([:account_id, :posture_provider_id, :iru_id, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
  end
end
