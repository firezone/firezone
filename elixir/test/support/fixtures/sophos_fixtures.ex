defmodule Portal.SophosFixtures do
  @moduledoc "Test helpers for Sophos posture providers and devices."

  import Portal.DevicePostureFixtures

  def sophos_posture_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || device_posture_account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    name = Map.get(attrs, :name, "Sophos #{unique}")
    parent = posture_provider_fixture(account, id, :sophos, name)

    provider_attrs = %{
      id: id,
      account_id: account.id,
      name: name,
      client_id: Map.get(attrs, :client_id, "sophos-client-#{unique}"),
      client_secret: Map.get(attrs, :client_secret, "sophos-test-client-secret-#{unique}"),
      tenant_id: Map.get(attrs, :tenant_id, Ecto.UUID.generate()),
      data_region_url: Map.get(attrs, :data_region_url, "https://api-us03.central.sophos.com"),
      is_verified: Map.get(attrs, :is_verified, true),
      is_disabled: Map.get(attrs, :is_disabled, false),
      disabled_reason: Map.get(attrs, :disabled_reason),
      synced_at: Map.get(attrs, :synced_at),
      errored_at: Map.get(attrs, :errored_at),
      error_message: Map.get(attrs, :error_message),
      error_email_count: Map.get(attrs, :error_email_count, 0)
    }

    %Portal.Sophos.PostureProvider{posture_provider: parent}
    |> Ecto.Changeset.cast(provider_attrs, Map.keys(provider_attrs))
    |> Portal.Sophos.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end

  def sophos_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    provider = Map.get(attrs, :provider) || sophos_posture_provider_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      sophos_id: Map.get(attrs, :sophos_id, Ecto.UUID.generate()),
      hostname: Map.get(attrs, :hostname, "endpoint-#{unique}"),
      serial_number: Map.get(attrs, :serial_number, "SOPHOS-SERIAL-#{unique}"),
      type: Map.get(attrs, :type, "computer"),
      os_platform: Map.get(attrs, :os_platform, "macOS"),
      os_name: Map.get(attrs, :os_name, "macOS Sequoia"),
      os_major_version: Map.get(attrs, :os_major_version, 15),
      os_minor_version: Map.get(attrs, :os_minor_version, 6),
      os_build: Map.get(attrs, :os_build, 1),
      health_overall: Map.get(attrs, :health_overall, "good"),
      health_threats_status: Map.get(attrs, :health_threats_status, "good"),
      health_services_status: Map.get(attrs, :health_services_status, "good"),
      encryption_overall_status: Map.get(attrs, :encryption_overall_status, "encrypted"),
      last_seen_at: Map.get(attrs, :last_seen_at),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    }

    %Portal.Sophos.Device{}
    |> Portal.Sophos.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end

  @doc "A minimal Endpoint API endpoint for sync tests."
  def sophos_api_endpoint_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "type" => "computer",
        "hostname" => "JANE-MBP",
        "os" => %{"platform" => "macOS", "name" => "macOS Sequoia"}
      },
      Enum.into(overrides, %{})
    )
  end

  @doc """
  Every top-level property of the Endpoint object in the Endpoint API v1 spec,
  as `GET /endpoints?view=full` returns it.
  """
  def full_sophos_api_endpoint_fixture do
    %{
      "id" => "7d0a1d3b-8a6f-4a55-9c1e-2f0b8e6c4d21",
      "type" => "computer",
      "tenant" => %{"id" => "57ca9a6b-885f-4e36-95ec-290548c26059"},
      "hostname" => "JANE-MBP",
      "health" => %{
        "overall" => "suspicious",
        "threats" => %{"status" => "good"},
        "services" => %{
          "status" => "suspicious",
          "serviceDetails" => [%{"name" => "Sophos Endpoint Defense", "status" => "stopped"}]
        }
      },
      "os" => %{
        "isServer" => false,
        "platform" => "macOS",
        "name" => "macOS Sequoia",
        "majorVersion" => 15,
        "minorVersion" => 6,
        "build" => 1
      },
      "ipv4Addresses" => ["192.168.1.10"],
      "ipv6Addresses" => ["2001:db8::1"],
      "macAddresses" => ["00:25:96:12:34:56"],
      "group" => %{"id" => "a3b0e1f2-4c5d-4e6f-8a9b-0c1d2e3f4a5b", "name" => "Engineering"},
      "groupHierarchy" => [
        %{"id" => "a3b0e1f2-4c5d-4e6f-8a9b-0c1d2e3f4a5b", "name" => "Engineering", "parentId" => "b3b0e1f2-4c5d-4e6f-8a9b-0c1d2e3f4a5b"},
        %{"id" => "b3b0e1f2-4c5d-4e6f-8a9b-0c1d2e3f4a5b", "name" => "Computers"}
      ],
      "associatedPerson" => %{
        "id" => "c3b0e1f2-4c5d-4e6f-8a9b-0c1d2e3f4a5b",
        "name" => "Jane Doe",
        "viaLogin" => "jane"
      },
      "tamperProtectionSupported" => true,
      "tamperProtectionEnabled" => true,
      "assignedProducts" => [
        %{"code" => "interceptX", "version" => "2024.3.1.5", "status" => "installed"}
      ],
      "packages" => %{
        "protection" => %{
          "assignedId" => "d3b0e1f2",
          "name" => "Recommended",
          "status" => "assigned",
          "available" => [%{"id" => "d3b0e1f2", "name" => "Recommended"}]
        }
      },
      "deviceSoftware" => %{
        "protection" => %{"assignedId" => "d3b0e1f2", "name" => "Recommended", "status" => "assigned"}
      },
      "lastSeenAt" => "2026-09-28T12:02:01.700Z",
      "lastOsUpdateAt" => "2026-09-20T08:00:00.000Z",
      "serialNumber" => "P28DA81LMD5T",
      "encryption" => %{
        "overallStatus" => "encrypted",
        "volumes" => [%{"volumeId" => "disk1s1", "status" => "encrypted"}]
      },
      "lockdown" => %{"status" => "notInstalled"},
      "tags" => [%{"key" => "environment", "value" => "production"}],
      "online" => true,
      "cloud" => %{"provider" => "aws", "instanceId" => "i-1234567890"},
      "isolation" => %{"status" => "notIsolated", "adminIsolated" => false, "selfIsolated" => false},
      "cloned" => false,
      "lastAgentUpdateAt" => "2026-09-27T12:02:01.700Z"
    }
  end
end
