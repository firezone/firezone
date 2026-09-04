defmodule Portal.Intune.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures

  alias Portal.Intune.{Device, PostureProvider, Sync}
  alias Portal.Microsoft.Graph.APIClient

  setup do
    enable_device_posture()
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"error" => "not mocked"}) end)
    :ok
  end

  test "stores every managed device in the tenant" do
    provider = intune_posture_provider_fixture()

    stub_managed_devices([
      managed_device(%{
        "id" => "managed-device-1",
        "serialNumber" => "serial-one",
        "deviceName" => "Alice's Surface"
      }),
      managed_device(%{
        "id" => "managed-device-2",
        "serialNumber" => "SERIAL-TWO",
        "deviceName" => "Bob's Mac"
      })
    ])

    assert :ok = perform_job(Sync, %{"account_id" => provider.account_id, "posture_provider_id" => provider.id})

    assert [first, second] = Repo.all(from(d in Device, order_by: d.intune_id))

    assert first.intune_id == "managed-device-1"
    assert first.device_name == "Alice's Surface"
    assert first.serial_number == "serial-one"
    assert first.compliance_state == "compliant"
    assert first.operating_system == "Windows"
    assert first.user_principal_name == "owner@example.com"
    assert first.is_encrypted
    assert first.enrolled_at == ~U[2026-08-01 01:02:03.000000Z]
    assert first.last_sync_at == ~U[2026-08-02 01:02:03.000000Z]
    assert first.account_id == provider.account_id
    assert first.posture_provider_id == provider.id

    assert second.intune_id == "managed-device-2"
    assert second.device_name == "Bob's Mac"
  end

  test "stores every property Microsoft Graph returns for a managed device" do
    provider = intune_posture_provider_fixture()

    stub_managed_devices([full_managed_device()])

    assert :ok = perform_job(Sync, %{"account_id" => provider.account_id, "posture_provider_id" => provider.id})

    device = Repo.get_by!(Device, intune_id: "705c034c")

    assert device.user_id == "User Id value"
    assert device.device_name == "Device Name value"
    assert device.managed_device_owner_type == "company"
    assert device.enrolled_at == ~U[2017-01-01 07:59:43.797191Z]
    assert device.last_sync_at == ~U[2017-01-01 08:02:49.320597Z]
    assert device.operating_system == "Operating System value"
    assert device.compliance_state == "compliant"
    assert device.management_state == "managed"
    assert device.jail_broken == true
    assert device.management_agent == "mdm"
    assert device.os_version == "Os Version value"
    assert device.eas_activated == true
    assert device.eas_device_id == "Eas Device Id value"
    assert device.eas_activated_at == ~U[2017-01-01 07:59:43.487878Z]
    assert device.entra_registered == true
    assert device.device_enrollment_type == "userEnrollment"
    assert device.email_address == "Email Address value"
    assert device.entra_device_id == "Azure ADDevice Id value"
    assert device.device_registration_state == "registered"
    assert device.device_category_display_name == "Device Category Display Name value"
    assert device.is_supervised == true
    assert device.exchange_last_successful_sync_at == ~U[2017-01-01 08:00:45.880308Z]
    assert device.exchange_access_state == "unknown"
    assert device.exchange_access_state_reason == "unknown"
    assert device.is_encrypted == true
    assert device.user_principal_name == "User Principal Name value"
    assert device.model == "Model value"
    assert device.manufacturer == "Manufacturer value"
    assert device.imei == "Imei value"
    assert device.compliance_grace_period_expiration_at == ~U[2017-01-01 07:56:44.951111Z]
    assert device.serial_number == "Serial Number value"
    assert device.phone_number == "Phone Number value"
    assert device.android_security_patch_level == ~D[2024-05-05]
    assert device.user_display_name == "User Display Name value"
    assert device.wifi_mac_address == "Wi Fi Mac Address value"
    assert device.subscriber_carrier == "Subscriber Carrier value"
    assert device.meid == "Meid value"
    assert device.total_storage_space_bytes == 8
    assert device.free_storage_space_bytes == 7
    assert device.managed_device_name == "Managed Device Name value"
    assert device.partner_reported_threat_state == "activated"
    assert device.require_user_enrollment_approval == true
    assert device.management_certificate_expires_at == ~U[2017-01-01 07:57:59.978965Z]
    assert device.iccid == "Iccid value"
    assert device.udid == "Udid value"
    assert device.notes == "Notes value"
    assert device.ethernet_mac_address == "Ethernet Mac Address value"
    assert device.physical_memory_bytes == 5
    assert device.enrollment_profile_name == "Enrollment Profile Name value"

    assert device.config_manager_inventory == true
    assert device.config_manager_modern_apps == true
    assert device.config_manager_resource_access == true
    assert device.config_manager_device_configuration == true
    assert device.config_manager_compliance_policy == true
    assert device.config_manager_windows_update_for_business == true

    assert device.attestation_last_update_date_time == "Last Update Date Time value"
    assert device.attestation_content_namespace_url == "https://example.com/namespace/"
    assert device.attestation_status == "Device Health Attestation Status value"
    assert device.attestation_content_version == "Content Version value"
    assert device.attestation_issued_at == ~U[2017-01-01 07:58:22.123103Z]
    assert device.attestation_identity_key == "Attestation Identity Key value"
    assert device.attestation_reset_count == 10
    assert device.attestation_restart_count == 12
    assert device.attestation_data_execution_policy_enabled == true
    assert device.attestation_bit_locker_enabled == true
    assert device.attestation_boot_manager_version == "Boot Manager Version value"
    assert device.attestation_code_integrity_check_version == "Code Integrity Check Version value"
    assert device.attestation_secure_boot == true
    assert device.attestation_boot_debugging == false

    assert device.attestation_operating_system_kernel_debugging == false

    assert device.attestation_code_integrity == true
    assert device.attestation_test_signing == false
    assert device.attestation_safe_mode == false
    assert device.attestation_windows_pe == false

    assert device.attestation_early_launch_anti_malware_driver_protection == true

    assert device.attestation_virtual_secure_mode == true
    assert device.attestation_pcr_hash_algorithm == "Pcr Hash Algorithm value"
    assert device.attestation_boot_app_security_version == "Boot App Security Version value"
    assert device.attestation_boot_manager_security_version == "Boot Manager Security Version value"
    assert device.attestation_tpm_version == "Tpm Version value"
    assert device.attestation_pcr0 == "Pcr0 value"

    assert device.attestation_secure_boot_config_policy_fingerprint ==
             "Secure Boot Configuration Policy Finger Print value"

    assert device.attestation_code_integrity_policy == "Code Integrity Policy value"
    assert device.attestation_boot_revision_list_info == "Boot Revision List Info value"
    assert device.attestation_operating_system_rev_list_info == "Operating System Rev List Info value"
    assert device.attestation_health_status_mismatch_info == "Health Status Mismatch Info value"
    assert device.attestation_supported == true

    assert [%{"actionName" => "Action Name value", "actionState" => "pending"}] =
             device.device_action_results
  end

  test "every column except our own bookkeeping is filled from the Graph payload" do
    provider = intune_posture_provider_fixture()
    stub_managed_devices([full_managed_device()])

    assert :ok = perform_job(Sync, %{"account_id" => provider.account_id, "posture_provider_id" => provider.id})

    ours = ~w[account_id posture_provider_id intune_id synced_at inserted_at updated_at]a
    device = Repo.get_by!(Device, intune_id: "705c034c")

    unset =
      (Device.__schema__(:fields) -- ours)
      |> Enum.filter(&is_nil(Map.fetch!(device, &1)))

    assert unset == [], "columns never populated from the Graph payload: #{inspect(unset)}"
  end

  # Every device in a real tenant carries these. 0001-01-01 means Intune has no
  # value, so it becomes nil. 9999-12-31 means "never expires", which is not the
  # same thing, so it stays a real date and keeps date comparisons truthful.
  test "discards the placeholder timestamps Intune sends for unset dates" do
    provider = intune_posture_provider_fixture()

    stub_managed_devices([
      managed_device(%{
        "id" => "managed-device",
        "easActivationDateTime" => "0001-01-01T00:00:00Z",
        "exchangeLastSuccessfulSyncDateTime" => "0001-01-01T00:00:00Z",
        "managementCertificateExpirationDate" => "0001-01-01T00:00:00Z",
        "complianceGracePeriodExpirationDateTime" => "9999-12-31T23:59:59.9999999Z",
        "enrolledDateTime" => "2026-08-01T01:02:03Z"
      })
    ])

    assert :ok = perform_job(Sync, %{"account_id" => provider.account_id, "posture_provider_id" => provider.id})

    device = Repo.get_by!(Device, intune_id: "managed-device")
    assert is_nil(device.eas_activated_at)
    assert is_nil(device.exchange_last_successful_sync_at)
    assert is_nil(device.management_certificate_expires_at)
    assert device.enrolled_at == ~U[2026-08-01 01:02:03.000000Z]

    assert device.compliance_grace_period_expiration_at == ~U[9999-12-31 23:59:59.999999Z]

    assert DateTime.compare(device.compliance_grace_period_expiration_at, DateTime.utc_now()) ==
             :gt
  end

  # Shapes taken from a real tenant rather than the reference: both complex
  # properties arrive as null, the seven properties Graph withholds from
  # collection queries arrive as null, unset strings arrive as "" rather than
  # null, and enum values turn up that the v1.0 reference does not list, which
  # is why these columns are plain strings and not Ecto.Enum.
  test "handles the shapes a real tenant returns" do
    provider = intune_posture_provider_fixture()

    stub_managed_devices([
      managed_device(%{
        "id" => "managed-device",
        "configurationManagerClientEnabledFeatures" => nil,
        "deviceHealthAttestationState" => nil,
        "deviceActionResults" => [],
        "udid" => nil,
        "ethernetMacAddress" => nil,
        "physicalMemoryInBytes" => nil,
        "requireUserEnrollmentApproval" => nil,
        "easDeviceId" => "",
        "meid" => "",
        "phoneNumber" => "",
        "subscriberCarrier" => "",
        "freeStorageSpaceInBytes" => 0,
        "deviceEnrollmentType" => "androidEnterpriseFullyManaged",
        "managementAgent" => "googleCloudDevicePolicyController",
        "jailBroken" => "Unknown"
      })
    ])

    assert :ok = perform_job(Sync, %{"account_id" => provider.account_id, "posture_provider_id" => provider.id})

    device = Repo.get_by!(Device, intune_id: "managed-device")
    assert is_nil(device.config_manager_inventory)
    assert is_nil(device.attestation_secure_boot)
    assert is_nil(device.udid)
    assert is_nil(device.physical_memory_bytes)
    assert is_nil(device.require_user_enrollment_approval)
    assert device.device_action_results == []

    assert is_nil(device.eas_device_id)
    assert is_nil(device.meid)
    assert is_nil(device.phone_number)
    assert is_nil(device.subscriber_carrier)
    assert device.free_storage_space_bytes == 0

    assert device.device_enrollment_type == "androidEnterpriseFullyManaged"
    assert device.management_agent == "googleCloudDevicePolicyController"
    assert is_nil(device.jail_broken)
  end

  test "follows every page of managed devices" do
    provider = intune_posture_provider_fixture()

    Req.Test.stub(APIClient, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/oauth2/v2.0/token") ->
          Req.Test.json(conn, %{"access_token" => "graph-token"})

        conn.query_string =~ "skiptoken" ->
          Req.Test.json(conn, %{"value" => [managed_device(%{"id" => "page-two-device"})]})

        true ->
          Req.Test.json(conn, %{
            "value" => [managed_device(%{"id" => "page-one-device"})],
            "@odata.nextLink" =>
              "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=abc"
          })
      end
    end)

    assert :ok = perform_job(Sync, %{"account_id" => provider.account_id, "posture_provider_id" => provider.id})

    assert Repo.aggregate(Device, :count) == 2
    assert Repo.get_by!(Device, intune_id: "page-one-device")
    assert Repo.get_by!(Device, intune_id: "page-two-device")
  end

  # Postgres caps a statement at 65535 bind parameters and a device carries a
  # column per Graph property, so a full page has to be split across inserts.
  test "stores a full Graph page without exceeding the bind parameter limit" do
    provider = intune_posture_provider_fixture()

    devices =
      Enum.map(1..999, fn i ->
        managed_device(%{"id" => "managed-device-#{i}", "serialNumber" => "SN#{i}"})
      end)

    stub_managed_devices(devices)

    assert :ok = perform_job(Sync, %{"account_id" => provider.account_id, "posture_provider_id" => provider.id})
    assert Repo.aggregate(Device, :count) == 999
  end

  test "deletes devices absent from a completed sync" do
    provider = intune_posture_provider_fixture()
    stale = intune_device_fixture(provider: provider, intune_id: "stale-device")

    stub_managed_devices([managed_device(%{"id" => "current-device"})])

    assert :ok = perform_job(Sync, %{account_id: provider.account_id, posture_provider_id: provider.id})
    refute Repo.get_by(Device, account_id: stale.account_id, intune_id: stale.intune_id)
    assert Repo.get_by!(Device, intune_id: "current-device")
  end

  test "updates the existing row for a managed device on later syncs" do
    provider = intune_posture_provider_fixture()

    stub_managed_devices([managed_device(%{"id" => "managed-device", "deviceName" => "Before"})])
    assert :ok = perform_job(Sync, %{account_id: provider.account_id, posture_provider_id: provider.id})
    first = Repo.get_by!(Device, intune_id: "managed-device")

    stub_managed_devices([managed_device(%{"id" => "managed-device", "deviceName" => "After"})])
    assert :ok = perform_job(Sync, %{account_id: provider.account_id, posture_provider_id: provider.id})

    assert Repo.aggregate(Device, :count) == 1
    updated = Repo.get_by!(Device, intune_id: "managed-device")
    assert updated.device_name == "After"
    assert updated.inserted_at == first.inserted_at
  end

  test "records the sync and clears earlier errors on the provider" do
    provider =
      intune_posture_provider_fixture(
        errored_at: DateTime.utc_now(),
        error_message: "Something went wrong",
        error_email_count: 4
      )

    stub_managed_devices([managed_device(%{"id" => "managed-device"})])

    assert :ok = perform_job(Sync, %{account_id: provider.account_id, posture_provider_id: provider.id})

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert provider.synced_at
    refute provider.errored_at
    refute provider.error_message
    assert provider.error_email_count == 0
  end

  test "does not sync a disabled or unverified provider" do
    disabled = intune_posture_provider_fixture(is_disabled: true)
    unverified = intune_posture_provider_fixture(is_verified: false)

    assert :ok = perform_job(Sync, %{account_id: disabled.account_id, posture_provider_id: disabled.id})
    assert :ok = perform_job(Sync, %{account_id: unverified.account_id, posture_provider_id: unverified.id})

    assert Repo.aggregate(Device, :count) == 0
  end

  test "does not sync an provider belonging to another account" do
    provider = intune_posture_provider_fixture()
    other_account = Portal.AccountFixtures.account_fixture()
    stub_managed_devices([full_managed_device()])

    assert :ok =
             perform_job(Sync, %{
               account_id: other_account.id,
               posture_provider_id: provider.id
             })

    assert Repo.aggregate(Device, :count) == 0
  end

  test "skips a job queued without an account id" do
    provider = intune_posture_provider_fixture()
    stub_managed_devices([full_managed_device()])

    assert :ok = perform_job(Sync, %{posture_provider_id: provider.id})

    assert Repo.aggregate(Device, :count) == 0
  end

  test "does not sync an account that lost the device_posture feature" do
    downgraded = Portal.AccountFixtures.account_fixture(features: %{device_posture: false})
    provider = intune_posture_provider_fixture(account: downgraded)
    stub_managed_devices([full_managed_device()])

    assert :ok =
             perform_job(Sync, %{
               account_id: provider.account_id,
               posture_provider_id: provider.id
             })

    assert Repo.aggregate(Device, :count) == 0
  end

  test "does not sync when the global device_posture flag is off" do
    enable_device_posture(false)
    provider = intune_posture_provider_fixture()
    stub_managed_devices([full_managed_device()])

    assert :ok =
             perform_job(Sync, %{
               account_id: provider.account_id,
               posture_provider_id: provider.id
             })

    assert Repo.aggregate(Device, :count) == 0
  end

  test "raises when Microsoft Graph returns a device without an ID" do
    provider = intune_posture_provider_fixture()

    stub_managed_devices([%{"deviceName" => "No ID"}])

    assert_raise Portal.Intune.SyncError, fn ->
      perform_job(Sync, %{account_id: provider.account_id, posture_provider_id: provider.id})
    end

    assert Repo.aggregate(Device, :count) == 0
  end

  test "raises when the access token request fails" do
    provider = intune_posture_provider_fixture()

    Req.Test.stub(APIClient, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_client"})
    end)

    assert_raise Portal.Intune.SyncError, fn ->
      perform_job(Sync, %{account_id: provider.account_id, posture_provider_id: provider.id})
    end
  end

  defp stub_managed_devices(devices) do
    Req.Test.stub(APIClient, fn conn ->
      if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
        Req.Test.json(conn, %{"access_token" => "graph-token"})
      else
        Req.Test.json(conn, %{"value" => devices})
      end
    end)
  end

  # The example response from the List managedDevices reference, so the mapping
  # can be checked against the documented payload.
  defp full_managed_device do
    %{
      "id" => "705c034c",
      "userId" => "User Id value",
      "deviceName" => "Device Name value",
      "managedDeviceOwnerType" => "company",
      "deviceActionResults" => [
        %{
          "actionName" => "Action Name value",
          "actionState" => "pending",
          "startDateTime" => "2016-12-31T23:58:46.7156189-08:00",
          "lastUpdatedDateTime" => "2017-01-01T00:00:56.8321556-08:00"
        }
      ],
      "enrolledDateTime" => "2016-12-31T23:59:43.797191-08:00",
      "lastSyncDateTime" => "2017-01-01T00:02:49.3205976-08:00",
      "operatingSystem" => "Operating System value",
      "complianceState" => "compliant",
      "managementState" => "managed",
      "jailBroken" => "True",
      "managementAgent" => "mdm",
      "osVersion" => "Os Version value",
      "easActivated" => true,
      "easDeviceId" => "Eas Device Id value",
      "easActivationDateTime" => "2016-12-31T23:59:43.4878784-08:00",
      "azureADRegistered" => true,
      "deviceEnrollmentType" => "userEnrollment",
      "emailAddress" => "Email Address value",
      "azureADDeviceId" => "Azure ADDevice Id value",
      "deviceRegistrationState" => "registered",
      "deviceCategoryDisplayName" => "Device Category Display Name value",
      "isSupervised" => true,
      "exchangeLastSuccessfulSyncDateTime" => "2017-01-01T00:00:45.8803083-08:00",
      "exchangeAccessState" => "unknown",
      "exchangeAccessStateReason" => "unknown",
      "isEncrypted" => true,
      "userPrincipalName" => "User Principal Name value",
      "model" => "Model value",
      "manufacturer" => "Manufacturer value",
      "imei" => "Imei value",
      "complianceGracePeriodExpirationDateTime" => "2016-12-31T23:56:44.951111-08:00",
      "serialNumber" => "Serial Number value",
      "phoneNumber" => "Phone Number value",
      "androidSecurityPatchLevel" => "2024-05-05",
      "userDisplayName" => "User Display Name value",
      "configurationManagerClientEnabledFeatures" => %{
        "inventory" => true,
        "modernApps" => true,
        "resourceAccess" => true,
        "deviceConfiguration" => true,
        "compliancePolicy" => true,
        "windowsUpdateForBusiness" => true
      },
      "wiFiMacAddress" => "Wi Fi Mac Address value",
      "deviceHealthAttestationState" => %{
        "lastUpdateDateTime" => "Last Update Date Time value",
        "contentNamespaceUrl" => "https://example.com/namespace/",
        "deviceHealthAttestationStatus" => "Device Health Attestation Status value",
        "contentVersion" => "Content Version value",
        "issuedDateTime" => "2016-12-31T23:58:22.1231038-08:00",
        "attestationIdentityKey" => "Attestation Identity Key value",
        "resetCount" => 10,
        "restartCount" => 12,
        "dataExcutionPolicy" => "enabled",
        "bitLockerStatus" => "On",
        "bootManagerVersion" => "Boot Manager Version value",
        "codeIntegrityCheckVersion" => "Code Integrity Check Version value",
        "secureBoot" => "True",
        "bootDebugging" => "False",
        "operatingSystemKernelDebugging" => "disabled",
        "codeIntegrity" => "1",
        "testSigning" => "0",
        "safeMode" => "no",
        "windowsPE" => "off",
        "earlyLaunchAntiMalwareDriverProtection" => "yes",
        "virtualSecureMode" => "enabled",
        "pcrHashAlgorithm" => "Pcr Hash Algorithm value",
        "bootAppSecurityVersion" => "Boot App Security Version value",
        "bootManagerSecurityVersion" => "Boot Manager Security Version value",
        "tpmVersion" => "Tpm Version value",
        "pcr0" => "Pcr0 value",
        "secureBootConfigurationPolicyFingerPrint" =>
          "Secure Boot Configuration Policy Finger Print value",
        "codeIntegrityPolicy" => "Code Integrity Policy value",
        "bootRevisionListInfo" => "Boot Revision List Info value",
        "operatingSystemRevListInfo" => "Operating System Rev List Info value",
        "healthStatusMismatchInfo" => "Health Status Mismatch Info value",
        "healthAttestationSupportedStatus" => "true"
      },
      "subscriberCarrier" => "Subscriber Carrier value",
      "meid" => "Meid value",
      "totalStorageSpaceInBytes" => 8,
      "freeStorageSpaceInBytes" => 7,
      "managedDeviceName" => "Managed Device Name value",
      "partnerReportedThreatState" => "activated",
      "requireUserEnrollmentApproval" => true,
      "managementCertificateExpirationDate" => "2016-12-31T23:57:59.9789653-08:00",
      "iccid" => "Iccid value",
      "udid" => "Udid value",
      "notes" => "Notes value",
      "ethernetMacAddress" => "Ethernet Mac Address value",
      "physicalMemoryInBytes" => 5,
      "enrollmentProfileName" => "Enrollment Profile Name value"
    }
  end

  defp managed_device(overrides) do
    Map.merge(
      %{
        "id" => "managed-device",
        "deviceName" => "Managed Device",
        "managedDeviceName" => "managed-device",
        "serialNumber" => "SERIAL",
        "azureADDeviceId" => Ecto.UUID.generate(),
        "userPrincipalName" => "owner@example.com",
        "userDisplayName" => "Device Owner",
        "operatingSystem" => "Windows",
        "osVersion" => "11.0",
        "model" => "Surface Laptop",
        "manufacturer" => "Microsoft",
        "complianceState" => "compliant",
        "managementAgent" => "mdm",
        "isEncrypted" => true,
        "enrolledDateTime" => "2026-08-01T01:02:03Z",
        "lastSyncDateTime" => "2026-08-02T01:02:03Z"
      },
      overrides
    )
  end
end
