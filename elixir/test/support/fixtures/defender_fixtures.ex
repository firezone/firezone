defmodule Portal.DefenderFixtures do
  @moduledoc """
  Test helpers for creating Defender posture providers and their devices.
  """

  import Portal.DevicePostureFixtures

  def defender_posture_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || device_posture_account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    name = Map.get(attrs, :name, "Microsoft Defender for Endpoint #{unique}")
    parent = posture_provider_fixture(account, id, :defender, name)

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

    %Portal.Defender.PostureProvider{posture_provider: parent}
    |> Ecto.Changeset.cast(provider_attrs, Map.keys(provider_attrs))
    |> Portal.Defender.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end

  def defender_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    provider = Map.get(attrs, :provider) || defender_posture_provider_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      defender_id: Map.get(attrs, :defender_id, Ecto.UUID.generate()),
      computer_dns_name: Map.get(attrs, :computer_dns_name, "machine#{unique}.contoso.com"),
      entra_device_id: Map.get(attrs, :entra_device_id, Ecto.UUID.generate()),
      entra_joined: Map.get(attrs, :entra_joined, true),
      machine_tags: Map.get(attrs, :machine_tags),
      os_platform: Map.get(attrs, :os_platform, "Windows11"),
      version: Map.get(attrs, :version, "23H2"),
      os_build: Map.get(attrs, :os_build, 22_631),
      os_architecture: Map.get(attrs, :os_architecture, "64-bit"),
      last_ip_address: Map.get(attrs, :last_ip_address),
      last_external_ip_address: Map.get(attrs, :last_external_ip_address),
      agent_version: Map.get(attrs, :agent_version, "10.8040.19041.4046"),
      health_status: Map.get(attrs, :health_status, "Active"),
      onboarding_status: Map.get(attrs, :onboarding_status, "Onboarded"),
      risk_score: Map.get(attrs, :risk_score, "Low"),
      exposure_level: Map.get(attrs, :exposure_level, "Low"),
      device_value: Map.get(attrs, :device_value, "Normal"),
      rbac_group_id: Map.get(attrs, :rbac_group_id),
      rbac_group_name: Map.get(attrs, :rbac_group_name),
      ip_addresses: Map.get(attrs, :ip_addresses),
      first_seen_at: Map.get(attrs, :first_seen_at),
      last_seen_at: Map.get(attrs, :last_seen_at),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    }

    %Portal.Defender.Device{}
    |> Portal.Defender.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end

  @doc "Build a defender API response payload for sync tests."
  def defender_api_machine_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "machine-1",
        "computerDnsName" => "alice.contoso.com",
        "osPlatform" => "Windows11",
        "healthStatus" => "Active",
        "onboardingStatus" => "Onboarded",
        "riskScore" => "Low"
      },
      Enum.into(overrides, %{})
    )
  end

  @doc "Build a defender API response payload for sync tests."
  # The example response from the List machines reference, so the mapping can be
  # checked against the documented payload.
  def full_defender_api_machine_fixture do
    %{
      "id" => "1e5bc9d7e413ddd7902c2932e418702b84d0cc07",
      "computerDnsName" => "mymachine1.contoso.com",
      "firstSeen" => "2018-08-02T14:55:03.7791856Z",
      "lastSeen" => "2021-01-25T07:27:36.052313Z",
      "osPlatform" => "Windows10",
      "version" => "1901",
      "osProcessor" => "x64",
      "osArchitecture" => "64-bit",
      "osBuild" => 19_042,
      "lastIpAddress" => "10.166.113.46",
      "lastExternalIpAddress" => "167.220.203.175",
      "agentVersion" => "10.8040.19041.4046",
      "healthStatus" => "Active",
      "onboardingStatus" => "Onboarded",
      "managedBy" => "Intune",
      "managedByStatus" => "Managed",
      "riskScore" => "High",
      "exposureLevel" => "Low",
      "deviceValue" => "Normal",
      "rbacGroupName" => "The-A-Team",
      "rbacGroupId" => 140,
      "isAadJoined" => true,
      "aadDeviceId" => "fd2e4d29-7072-4195-aaa5-1af139b78028",
      "machineTags" => ["Tag1", "Tag2"],
      "isPotentialDuplication" => false,
      "mergedIntoMachineId" => "merged-machine-id",
      "isExcluded" => false,
      "exclusionReason" => nil,
      "ipAddresses" => [
        %{
          "ipAddress" => "10.166.113.47",
          "macAddress" => "8CEC4B897E73",
          "operationalStatus" => "Up"
        },
        %{
          "ipAddress" => "2a01:110:68:4:59e4:3916:3b3e:4f96",
          "macAddress" => "8CEC4B897E73",
          "operationalStatus" => "Up"
        }
      ],
      "vmMetadata" => %{
        "vmId" => "vm-id-value",
        "cloudProvider" => "Azure",
        "resourceId" => "/subscriptions/sub-id/resourceGroups/rg/vm",
        "subscriptionId" => "sub-id"
      }
    }
  end
end
