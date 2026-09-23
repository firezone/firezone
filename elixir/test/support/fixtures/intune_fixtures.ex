defmodule Portal.IntuneFixtures do
  @moduledoc """
  Test helpers for creating Intune posture providers and their devices.
  """

  import Portal.DevicePostureFixtures

  def intune_posture_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || device_posture_account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    name = Map.get(attrs, :name, "Microsoft Intune #{unique}")
    parent = posture_provider_fixture(account, id, :intune, name)

    provider_attrs = %{
      id: id,
      account_id: account.id,
      name: name,
      tenant_id: Map.get(attrs, :tenant_id, Ecto.UUID.generate()),
      is_verified: Map.get(attrs, :is_verified, true),
      is_disabled: Map.get(attrs, :is_disabled, false),
      disabled_reason: Map.get(attrs, :disabled_reason),
      synced_at: Map.get(attrs, :synced_at),
      errored_at: Map.get(attrs, :errored_at),
      error_message: Map.get(attrs, :error_message),
      error_email_count: Map.get(attrs, :error_email_count, 0)
    }

    %Portal.Intune.PostureProvider{posture_provider: parent}
    |> Ecto.Changeset.cast(provider_attrs, Map.keys(provider_attrs))
    |> Portal.Intune.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end

  def intune_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    provider = Map.get(attrs, :provider) || intune_posture_provider_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      intune_id: Map.get(attrs, :intune_id, Ecto.UUID.generate()),
      device_name: Map.get(attrs, :device_name, "Inventory Device #{unique}"),
      managed_device_name: Map.get(attrs, :managed_device_name),
      serial_number: Map.get(attrs, :serial_number, "INTUNE-SERIAL-#{unique}"),
      entra_device_id: Map.get(attrs, :entra_device_id, Ecto.UUID.generate()),
      user_id: Map.get(attrs, :user_id),
      user_principal_name: Map.get(attrs, :user_principal_name),
      user_display_name: Map.get(attrs, :user_display_name),
      email_address: Map.get(attrs, :email_address),
      operating_system: Map.get(attrs, :operating_system, "Windows"),
      os_version: Map.get(attrs, :os_version, "11"),
      model: Map.get(attrs, :model),
      manufacturer: Map.get(attrs, :manufacturer),
      compliance_state: Map.get(attrs, :compliance_state, "compliant"),
      management_agent: Map.get(attrs, :management_agent, "mdm"),
      managed_device_owner_type: Map.get(attrs, :managed_device_owner_type),
      device_enrollment_type: Map.get(attrs, :device_enrollment_type),
      device_registration_state: Map.get(attrs, :device_registration_state),
      partner_reported_threat_state: Map.get(attrs, :partner_reported_threat_state),
      jail_broken: Map.get(attrs, :jail_broken),
      is_encrypted: Map.get(attrs, :is_encrypted),
      is_supervised: Map.get(attrs, :is_supervised),
      enrolled_at: Map.get(attrs, :enrolled_at),
      last_sync_at: Map.get(attrs, :last_sync_at),
      compliance_grace_period_expiration_at:
        Map.get(attrs, :compliance_grace_period_expiration_at),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    }

    %Portal.Intune.Device{}
    |> Portal.Intune.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end

  @doc "Build a intune API response payload for sync tests."
  def intune_api_device_fixture(overrides \\ %{}) do
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
      Enum.into(overrides, %{})
    )
  end

  @doc "Build a intune API response payload for sync tests."
  # The example response from the List managedDevices reference, so the mapping
  # can be checked against the documented payload.
  def full_intune_api_device_fixture do
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
end
