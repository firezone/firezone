defmodule Portal.GoogleEndpoint.Device do
  @moduledoc """
  A device known to Google Endpoint Management, as the Cloud Identity API
  `GET /v1/devices` reports it.

  The Android attributes are flattened into columns. The Endpoint Verification
  attributes stay JSON, as their signals depend on what the customer collects.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "google_endpoint_devices" do
    belongs_to :account, Portal.Account, primary_key: true
    field :google_id, :string, primary_key: true
    belongs_to :posture_provider, Portal.PostureProvider

    field :device_id, :string
    field :unified_device_id, :string
    field :device_type, :string
    field :owner_type, :string
    field :management_state, :string
    field :compromised_state, :string
    field :encryption_state, :string
    field :model, :string
    field :manufacturer, :string
    field :brand, :string
    field :hostname, :string
    field :os_version, :string
    field :release_version, :string
    field :build_number, :string
    field :kernel_version, :string
    field :baseband_version, :string
    field :bootloader_version, :string
    field :security_patch_at, :utc_datetime_usec
    field :serial_number, :string
    field :asset_tag, :string
    field :imei, :string
    field :meid, :string
    field :network_operator, :string
    field :wifi_mac_addresses, {:array, :string}
    field :other_accounts, {:array, :string}
    field :enabled_developer_options, :boolean
    field :enabled_usb_debugging, :boolean
    field :android_enabled_unknown_sources, :boolean
    field :android_supports_work_profile, :boolean
    field :android_owner_profile_account, :boolean
    field :android_ownership_privilege, :string
    field :android_verified_boot, :boolean
    field :android_cts_profile_match, :boolean
    field :android_verify_apps_enabled, :boolean
    field :android_has_potentially_harmful_apps, :boolean
    field :endpoint_verification_attributes, :map
    field :registered_at, :utc_datetime_usec
    field :last_sync_at, :utc_datetime_usec

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
    |> validate_required([:account_id, :posture_provider_id, :google_id, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
  end
end
