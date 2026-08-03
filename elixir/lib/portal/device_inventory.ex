defmodule Portal.DeviceInventory do
  @moduledoc """
  Read-only projection of provider inventory and Firezone client connection records.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id

  schema "device_inventory" do
    field :id, :binary_id, primary_key: true
    belongs_to :account, Portal.Account
    field :device_id, :binary_id
    field :intune_device_id, :binary_id
    field :device_integration_id, :binary_id
    belongs_to :actor, Portal.Actor

    field :name, :string
    field :connected, :boolean
    field :firezone_id, :string
    field :ipv4, Portal.Types.IP
    field :ipv6, Portal.Types.IP
    field :device_serial, :string
    field :device_uuid, :string
    field :identifier_for_vendor, :string
    field :firebase_installation_id, :string
    field :hostname, :string

    field :last_attested_device_serial, :string
    field :last_attested_device_uuid, :string
    field :last_attested_mdm_device_id, :string
    field :last_attested_cert_serial, :string
    field :last_attested_cert_fingerprint, :string
    field :last_attested_at, :utc_datetime_usec
    field :verified_at, :utc_datetime_usec

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Portal.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_version, :string
    field :last_seen_at, :utc_datetime_usec

    field :intune_id, :string
    field :intune_device_name, :string
    field :intune_managed_device_name, :string
    field :intune_serial_number, :string
    field :intune_entra_device_id, :string
    field :intune_user_id, :string
    field :intune_user_principal_name, :string
    field :intune_user_display_name, :string
    field :intune_email_address, :string
    field :intune_operating_system, :string
    field :intune_os_version, :string
    field :intune_model, :string
    field :intune_manufacturer, :string
    field :intune_compliance_state, :string
    field :intune_management_agent, :string
    field :intune_managed_device_owner_type, :string
    field :intune_device_enrollment_type, :string
    field :intune_device_registration_state, :string
    field :intune_partner_reported_threat_state, :string
    field :intune_jail_broken, :string
    field :intune_is_encrypted, :boolean
    field :intune_is_supervised, :boolean
    field :intune_enrolled_at, :utc_datetime_usec
    field :intune_last_sync_at, :utc_datetime_usec
    field :intune_compliance_grace_period_expiration_at, :utc_datetime_usec
    field :intune_attributes, :map

    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    field :online?, :boolean, virtual: true, default: false
  end
end
