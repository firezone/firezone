defmodule Portal.SentinelOneFixtures do
  @moduledoc "Test helpers for SentinelOne posture providers and devices."

  import Portal.DevicePostureFixtures

  def sentinelone_posture_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || device_posture_account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    name = Map.get(attrs, :name, "SentinelOne #{unique}")
    parent = posture_provider_fixture(account, id, :sentinelone, name)

    provider_attrs = %{
      id: id,
      account_id: account.id,
      name: name,
      management_url:
        Map.get(attrs, :management_url, "https://tenant-#{unique}.sentinelone.net"),
      api_token: Map.get(attrs, :api_token, "sentinelone-test-api-token-#{unique}"),
      is_verified: Map.get(attrs, :is_verified, true),
      is_disabled: Map.get(attrs, :is_disabled, false),
      disabled_reason: Map.get(attrs, :disabled_reason),
      synced_at: Map.get(attrs, :synced_at),
      errored_at: Map.get(attrs, :errored_at),
      error_message: Map.get(attrs, :error_message),
      error_email_count: Map.get(attrs, :error_email_count, 0)
    }

    %Portal.SentinelOne.PostureProvider{posture_provider: parent}
    |> Ecto.Changeset.cast(provider_attrs, Map.keys(provider_attrs))
    |> Portal.SentinelOne.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end

  def sentinelone_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    provider = Map.get(attrs, :provider) || sentinelone_posture_provider_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      sentinelone_id: Map.get(attrs, :sentinelone_id, Integer.to_string(unique)),
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate()),
      computer_name: Map.get(attrs, :computer_name, "endpoint-#{unique}"),
      serial_number: Map.get(attrs, :serial_number, "S1-SERIAL-#{unique}"),
      os_name: Map.get(attrs, :os_name, "Windows 11"),
      os_type: Map.get(attrs, :os_type, "windows"),
      agent_version: Map.get(attrs, :agent_version, "24.1.4.257"),
      is_active: Map.get(attrs, :is_active, true),
      infected: Map.get(attrs, :infected, false),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    }

    %Portal.SentinelOne.Device{}
    |> Portal.SentinelOne.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end

  @doc "Build a sentinel one API response payload for sync tests."
  def sentinelone_api_agent_fixture(overrides \\ %{}) do
    agent =
      Map.merge(
        %{
          "id" => "225494730938493804",
          "computerName" => "JOHN-WIN-4125",
          "osName" => "Windows 11",
          "osType" => "windows",
          "agentVersion" => "24.1.4.257",
          "isActive" => true,
          "infected" => false
        },
        Enum.into(overrides, %{})
      )

    Map.put_new(agent, "uuid", "agent-uuid-#{agent["id"]}")
  end

  @doc "Build a sentinel one API response payload for sync tests."
  # Every top-level property in SentinelOne's Management API v2.1
  # agents.schemas_AgentViewSchema_many_200 response schema.
  def full_sentinelone_api_agent_fixture do
    timestamp = "2026-08-25T04:49:26.257525Z"

    %{
      "id" => "225494730938493804",
      "createdAt" => timestamp,
      "updatedAt" => timestamp,
      "groupUpdatedAt" => timestamp,
      "policyUpdatedAt" => timestamp,
      "accountId" => "225494730938493801",
      "accountName" => "Example Account",
      "siteId" => "225494730938493802",
      "siteName" => "Example Site",
      "groupId" => "225494730938493803",
      "groupName" => "Production",
      "licenseKey" => "license-key",
      "uuid" => "ff819e70af13be381993075eb0ce5f2f6de05be2",
      "agentVersion" => "24.1.4.257",
      "networkInterfaces" => [
        %{
          "id" => "225494730938493805",
          "name" => "Ethernet",
          "physical" => "00:25:96:FF:FE:12:34:56",
          "inet" => ["192.168.1.10"],
          "inet6" => ["2001:db8::1"],
          "gatewayMacAddress" => "00:25:96:FF:FE:12",
          "gatewayIp" => "192.168.1.1"
        }
      ],
      "domain" => "example.com",
      "computerName" => "JOHN-WIN-4125",
      "osName" => "Windows 11",
      "osRevision" => "22631",
      "osArch" => "64 bit",
      "osUsername" => "jane",
      "osStartTime" => timestamp,
      "osType" => "windows",
      "totalMemory" => 8192,
      "modelName" => "Example Laptop",
      "machineType" => "laptop",
      "cpuId" => "Example CPU",
      "cpuCount" => 1,
      "coreCount" => 8,
      "externalIp" => "203.0.113.10",
      "groupIp" => "192.168.1.x",
      "activeThreats" => 1,
      "infected" => true,
      "threatRebootRequired" => true,
      "lastActiveDate" => timestamp,
      "isActive" => true,
      "isUpToDate" => true,
      "networkStatus" => "connected",
      "registeredAt" => timestamp,
      "isPendingUninstall" => false,
      "isUninstalled" => false,
      "isDecommissioned" => false,
      "encryptedApplications" => true,
      "lastLoggedInUserName" => "jane",
      "activeDirectory" => %{
        "lastUserDistinguishedName" => "CN=Jane,CN=Users,DC=example,DC=com",
        "lastUserMemberOf" => ["CN=Users,DC=example,DC=com"],
        "computerDistinguishedName" => "CN=JOHN-WIN-4125,CN=Computers,DC=example,DC=com",
        "computerMemberOf" => ["CN=Computers,DC=example,DC=com"],
        "userPrincipalName" => "jane@example.com",
        "mail" => "jane@example.com"
      },
      "scanStatus" => "finished",
      "scanStartedAt" => timestamp,
      "scanFinishedAt" => timestamp,
      "scanAbortedAt" => timestamp,
      "fullDiskScanLastUpdatedAt" => timestamp,
      "mitigationMode" => "protect",
      "mitigationModeSuspicious" => "detect",
      "userActionsNeeded" => ["reboot_needed"],
      "missingPermissions" => ["user_action_needed_notifications"],
      "consoleMigrationStatus" => "N/A",
      "appsVulnerabilityStatus" => "up_to_date",
      "inRemoteShellSession" => false,
      "allowRemoteShell" => true,
      "locations" => [%{"id" => "1", "name" => "Office", "scope" => "site"}],
      "locationType" => "specific",
      "externalId" => "asset-123",
      "serialNumber" => "SERIAL123",
      "machineSid" => "S-1-5-21-123",
      "installerType" => ".msi",
      "rangerVersion" => "24.1.4.257",
      "rangerStatus" => "Enabled",
      "lastIpToMgmt" => "192.168.1.10",
      "operationalState" => "na",
      "operationalStateExpiration" => timestamp,
      "remoteProfilingState" => "disabled",
      "remoteProfilingStateExpiration" => timestamp,
      "networkQuarantineEnabled" => true,
      "firewallEnabled" => true,
      "locationEnabled" => true,
      "cloudProviders" => %{
        "AWS" => %{
          "cloudAccount" => "123456789012",
          "cloudInstanceId" => "i-1234567890",
          "cloudLocation" => "us-west-2"
        }
      },
      "storageType" => "local",
      "storageName" => "C:",
      "detectionState" => "full_mode",
      "firstFullModeTime" => timestamp,
      "tags" => %{
        "sentinelone" => [
          %{
            "id" => "225494730938493806",
            "key" => "environment",
            "value" => "production",
            "assignedAt" => timestamp,
            "assignedBy" => "Jane Doe",
            "assignedById" => "225494730938493807"
          }
        ]
      },
      "showAlertIcon" => true,
      "lastSuccessfulScanDate" => timestamp,
      "proxyStates" => %{
        "console" => true,
        "deepVisibility" => true,
        "pacFileUsage" => true,
        "proxyMethod" => "Auto",
        "consoleProxyAddress" => "proxy.example.com:8080",
        "deepVisibilityProxyAddress" => "proxy.example.com:8080"
      },
      "containerizedWorkloadCounts" => %{
        "podsCount" => 2,
        "containersCount" => 4,
        "tasksCount" => 1
      },
      "hasContainerizedWorkload" => true,
      "isAdConnector" => true,
      "isHyperAutomate" => true,
      "activeProtection" => ["edr", "idr"]
    }
  end
end
