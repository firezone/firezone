defmodule Portal.SentinelOne.Device do
  @moduledoc """
  A SentinelOne Management Console `AgentView` endpoint record.

  The columns mirror the Management API v2.1 `GET /agents` response schema.
  Nested objects with a stable, scalar schema are flattened; open-ended or
  repeated objects remain JSON so no endpoint telemetry is discarded.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sentinelone_devices" do
    belongs_to :account, Portal.Account, primary_key: true
    field :uuid, :string, primary_key: true
    belongs_to :posture_provider, Portal.PostureProvider

    field :source_created_at, :utc_datetime_usec
    field :source_updated_at, :utc_datetime_usec
    field :group_updated_at, :utc_datetime_usec
    field :policy_updated_at, :utc_datetime_usec

    field :sentinelone_account_id, :string
    field :account_name, :string
    field :site_id, :string
    field :site_name, :string
    field :group_id, :string
    field :group_name, :string
    field :license_key, :string, redact: true
    field :sentinelone_id, :string
    field :agent_version, :string

    field :network_interfaces, {:array, :map}
    field :domain, :string
    field :computer_name, :string
    field :os_name, :string
    field :os_revision, :string
    field :os_arch, :string
    field :os_username, :string
    field :os_start_time, :utc_datetime_usec
    field :os_type, :string
    field :total_memory, :integer
    field :model_name, :string
    field :machine_type, :string
    field :cpu_id, :string
    field :cpu_count, :integer
    field :core_count, :integer
    field :external_ip, :string
    field :group_ip, :string

    field :active_threats, :integer
    field :infected, :boolean
    field :threat_reboot_required, :boolean
    field :last_active_at, :utc_datetime_usec
    field :is_active, :boolean
    field :is_up_to_date, :boolean
    field :network_status, :string
    field :registered_at, :utc_datetime_usec
    field :is_pending_uninstall, :boolean
    field :is_uninstalled, :boolean
    field :is_decommissioned, :boolean
    field :encrypted_applications, :boolean
    field :last_logged_in_user_name, :string

    field :ad_last_user_distinguished_name, :string
    field :ad_last_user_member_of, {:array, :string}
    field :ad_computer_distinguished_name, :string
    field :ad_computer_member_of, {:array, :string}
    field :ad_user_principal_name, :string
    field :ad_mail, :string

    field :scan_status, :string
    field :scan_started_at, :utc_datetime_usec
    field :scan_finished_at, :utc_datetime_usec
    field :scan_aborted_at, :utc_datetime_usec
    field :full_disk_scan_updated_at, :utc_datetime_usec
    field :mitigation_mode, :string
    field :mitigation_mode_suspicious, :string
    field :user_actions_needed, {:array, :string}
    field :missing_permissions, {:array, :string}
    field :console_migration_status, :string
    field :apps_vulnerability_status, :string

    field :in_remote_shell_session, :boolean
    field :allow_remote_shell, :boolean
    field :locations, {:array, :map}
    field :location_type, :string
    field :external_id, :string
    field :serial_number, :string
    field :machine_sid, :string
    field :installer_type, :string
    field :ranger_version, :string
    field :ranger_status, :string
    field :last_ip_to_management, :string
    field :operational_state, :string
    field :operational_state_expires_at, :utc_datetime_usec
    field :remote_profiling_state, :string
    field :remote_profiling_state_expires_at, :utc_datetime_usec
    field :network_quarantine_enabled, :boolean
    field :firewall_enabled, :boolean
    field :location_enabled, :boolean

    field :cloud_providers, :map
    field :storage_type, :string
    field :storage_name, :string
    field :detection_state, :string
    field :first_full_mode_at, :utc_datetime_usec
    field :tags, {:array, :map}
    field :show_alert_icon, :boolean
    field :last_successful_scan_at, :utc_datetime_usec

    field :proxy_console, :boolean
    field :proxy_deep_visibility, :boolean
    field :proxy_pac_file_usage, :boolean
    field :proxy_method, :string
    field :proxy_console_address, :string
    field :proxy_deep_visibility_address, :string

    field :protected_pods_count, :integer
    field :protected_containers_count, :integer
    field :protected_tasks_count, :integer
    field :has_containerized_workload, :boolean
    field :is_ad_connector, :boolean
    field :is_hyper_automate, :boolean
    field :active_protection, {:array, :string}

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
    |> validate_required([:account_id, :posture_provider_id, :uuid, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
  end
end
