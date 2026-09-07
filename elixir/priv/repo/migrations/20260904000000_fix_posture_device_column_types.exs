defmodule Portal.Repo.Migrations.FixPostureDeviceColumnTypes do
  use Ecto.Migration

  # Mirror columns are dropped and re-added rather than converted in place. The
  # next sync refills them, and no USING clause is needed for the base64 IPs.

  @intune_attestation_flags ~w[
    attestation_data_execution_policy_enabled
    attestation_bit_locker_enabled
    attestation_secure_boot
    attestation_boot_debugging
    attestation_operating_system_kernel_debugging
    attestation_code_integrity
    attestation_test_signing
    attestation_safe_mode
    attestation_windows_pe
    attestation_early_launch_anti_malware_driver_protection
    attestation_virtual_secure_mode
    attestation_supported
  ]a

  @intune_attestation_strings ~w[
    attestation_data_execution_policy
    attestation_bit_locker_status
    attestation_secure_boot
    attestation_boot_debugging
    attestation_operating_system_kernel_debugging
    attestation_code_integrity
    attestation_test_signing
    attestation_safe_mode
    attestation_windows_pe
    attestation_early_launch_anti_malware_driver_protection
    attestation_virtual_secure_mode
    attestation_supported_status
  ]a

  def up do
    alter table(:intune_devices) do
      remove(:jail_broken)
      add(:jail_broken, :boolean)
      remove(:android_security_patch_level)
      add(:android_security_patch_level, :date)
      modify(:attestation_reset_count, :bigint)
      modify(:attestation_restart_count, :bigint)

      for column <- @intune_attestation_strings do
        remove(column)
      end

      for column <- @intune_attestation_flags do
        add(column, :boolean)
      end
    end

    alter table(:defender_devices) do
      remove(:last_ip_address)
      add(:last_ip_address, :inet)
      remove(:last_external_ip_address)
      add(:last_external_ip_address, :inet)
      remove(:rbac_group_id)
      add(:rbac_group_id, :integer)
    end

    alter table(:santa_devices) do
      remove(:last_preflight_ip)
      add(:last_preflight_ip, :inet)
    end

    alter table(:sentinelone_devices) do
      remove(:external_ip)
      add(:external_ip, :inet)
      remove(:last_ip_to_management)
      add(:last_ip_to_management, :inet)
    end
  end

  def down do
    alter table(:intune_devices) do
      remove(:jail_broken)
      add(:jail_broken, :string)
      remove(:android_security_patch_level)
      add(:android_security_patch_level, :string)
      modify(:attestation_reset_count, :integer)
      modify(:attestation_restart_count, :integer)

      for column <- @intune_attestation_flags do
        remove(column)
      end

      for column <- @intune_attestation_strings do
        add(column, :string)
      end
    end

    alter table(:defender_devices) do
      remove(:last_ip_address)
      add(:last_ip_address, :string)
      remove(:last_external_ip_address)
      add(:last_external_ip_address, :string)
      remove(:rbac_group_id)
      add(:rbac_group_id, :string)
    end

    alter table(:santa_devices) do
      remove(:last_preflight_ip)
      add(:last_preflight_ip, :string)
    end

    alter table(:sentinelone_devices) do
      remove(:external_ip)
      add(:external_ip, :string)
      remove(:last_ip_to_management)
      add(:last_ip_to_management, :string)
    end
  end
end
