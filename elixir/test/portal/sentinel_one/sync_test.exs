defmodule Portal.SentinelOne.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.DevicePostureFixtures
  import Portal.SentinelOneFixtures
  import ExUnit.CaptureLog

  alias Portal.SentinelOne.{APIClient, Device, PostureProvider, Sync}

  # Exact top-level property set from SentinelOne's official Management API
  # v2.1 Swagger definition for GET /web/api/v2.1/agents.
  @agent_view_properties ~w[
    accountId accountName activeDirectory activeProtection activeThreats agentVersion
    allowRemoteShell appsVulnerabilityStatus cloudProviders computerName
    consoleMigrationStatus containerizedWorkloadCounts coreCount cpuCount cpuId createdAt
    detectionState domain encryptedApplications externalId externalIp firewallEnabled
    firstFullModeTime fullDiskScanLastUpdatedAt groupId groupIp groupName groupUpdatedAt
    hasContainerizedWorkload id inRemoteShellSession infected installerType isActive
    isAdConnector isDecommissioned isHyperAutomate isPendingUninstall isUninstalled
    isUpToDate lastActiveDate lastIpToMgmt lastLoggedInUserName lastSuccessfulScanDate
    licenseKey locationEnabled locationType locations machineSid machineType missingPermissions
    mitigationMode mitigationModeSuspicious modelName networkInterfaces networkQuarantineEnabled
    networkStatus operationalState operationalStateExpiration osArch osName osRevision osStartTime
    osType osUsername policyUpdatedAt proxyStates rangerStatus rangerVersion registeredAt
    remoteProfilingState remoteProfilingStateExpiration scanAbortedAt scanFinishedAt scanStartedAt
    scanStatus serialNumber showAlertIcon siteId siteName storageName storageType tags
    threatRebootRequired totalMemory updatedAt userActionsNeeded uuid
  ]

  setup do
    enable_device_posture()
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"errors" => ["not mocked"]}) end)
    :ok
  end

  test "stores every property in SentinelOne's documented AgentView schema" do
    provider = sentinelone_posture_provider_fixture()
    agent = full_agent()

    assert length(@agent_view_properties) == 88
    assert MapSet.new(Map.keys(agent)) == MapSet.new(@agent_view_properties)
    assert MapSet.new(Sync.agent_view_properties()) == MapSet.new(@agent_view_properties)

    stub_agents([agent])

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, uuid: "ff819e70af13be381993075eb0ce5f2f6de05be2")

    inventory_fields =
      Device.__schema__(:fields) --
        [
          :account_id,
          :posture_provider_id,
          :sentinelone_id,
          :synced_at,
          :inserted_at,
          :updated_at
        ]

    missing_fields = Enum.filter(inventory_fields, &is_nil(Map.fetch!(device, &1)))
    assert missing_fields == []

    assert device.account_id == provider.account_id
    assert device.posture_provider_id == provider.id
    assert device.computer_name == "JOHN-WIN-4125"
    assert device.os_start_time == ~U[2026-08-25 04:49:26.257525Z]
    assert device.total_memory == 8192
    assert device.ad_user_principal_name == "jane@example.com"
    assert device.ad_computer_member_of == ["CN=Computers,DC=example,DC=com"]
    assert device.network_interfaces == [
             %{
               "id" => "225494730938493805",
               "name" => "Ethernet",
               "physical" => "00:25:96:FF:FE:12:34:56",
               "inet" => ["192.168.1.10"],
               "inet6" => ["2001:db8::1"],
               "gatewayMacAddress" => "00:25:96:FF:FE:12",
               "gatewayIp" => "192.168.1.1"
             }
           ]

    assert device.tags == [
             %{
               "id" => "225494730938493806",
               "key" => "environment",
               "value" => "production",
               "assignedAt" => "2026-08-25T04:49:26.257525Z",
               "assignedBy" => "Jane Doe",
               "assignedById" => "225494730938493807"
             }
           ]

    assert device.cloud_providers == agent["cloudProviders"]
    assert device.proxy_console
    assert device.protected_containers_count == 4
    assert device.active_protection == ["edr", "idr"]
  end

  test "follows nextCursor instead of paginating with a moving offset" do
    provider = sentinelone_posture_provider_fixture()
    test_pid = self()

    first_page =
      Enum.map(1..1000, fn n ->
        agent(%{"id" => Integer.to_string(225_494_730_938_493_000 + n)})
      end)

    Req.Test.stub(APIClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:request, conn.query_params, Plug.Conn.get_req_header(conn, "authorization")})

      case conn.query_params["cursor"] do
        nil ->
          Req.Test.json(conn, %{
            "data" => first_page,
            "pagination" => %{"nextCursor" => "YWdlbnRfaWQ6MjI1NDk0NzMwOTM4NDk0MDAw", "totalItems" => 1001}
          })

        "YWdlbnRfaWQ6MjI1NDk0NzMwOTM4NDk0MDAw" ->
          Req.Test.json(conn, %{
            "data" => [agent(%{"id" => "225494730938494001"})],
            "pagination" => %{"nextCursor" => nil, "totalItems" => 1001}
          })
      end
    end)

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 1001

    assert_received {:request,
                     %{
                       "limit" => "1000",
                       "sortBy" => "id",
                       "sortOrder" => "asc"
                     }, [authorization]}

    assert String.starts_with?(authorization, "ApiToken sentinelone-test-api-token-")

    assert_received {:request,
                     %{
                       "cursor" => "YWdlbnRfaWQ6MjI1NDk0NzMwOTM4NDk0MDAw",
                       "limit" => "1000",
                       "sortBy" => "id",
                       "sortOrder" => "asc"
                     }, _authorization}
  end

  test "raises rather than treating an invalid response as an empty tenant" do
    provider = sentinelone_posture_provider_fixture()

    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"agents" => []}) end)

    assert_raise Portal.SentinelOne.SyncError, fn ->
      perform_job(Sync, sync_args(provider))
    end
  end

  test "skips and warns when an agent has no uuid without failing the page" do
    provider = sentinelone_posture_provider_fixture()
    valid_agent = agent(%{"uuid" => "valid-agent-uuid"})

    invalid_agent =
      agent(%{
        "uuid" => nil,
        "id" => "225494730938493804",
        "computerName" => "WORKSTATION-1",
        "serialNumber" => "SERIAL-1",
        "siteId" => "225494730938493805"
      })

    stub_agents([invalid_agent, valid_agent])

    log = capture_log(fn ->
      perform_job(Sync, sync_args(provider))
    end)

    assert Repo.get_by!(Device, account_id: provider.account_id, uuid: valid_agent["uuid"])
    assert Repo.aggregate(Device, :count) == 1
    assert log =~ "Skipping SentinelOne agent without a UUID"
    assert log =~ "account_id=#{provider.account_id}"
    assert log =~ "sentinelone_agent_id=225494730938493804"
    assert log =~ "computer_name=WORKSTATION-1"
    assert log =~ "serial_number=SERIAL-1"
    assert log =~ "site_id=225494730938493805"
  end

  test "uses the universal uuid rather than the numeric API id as device identity" do
    provider = sentinelone_posture_provider_fixture()
    uuid = "ff819e70af13be381993075eb0ce5f2f6de05be2"

    stub_agents([agent(%{"id" => "225494730938493804", "uuid" => uuid})])
    assert :ok = perform_job(Sync, sync_args(provider))

    stub_agents([agent(%{"id" => "225494730938493999", "uuid" => uuid})])
    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.aggregate(Device, :count) == 1
    assert Repo.get_by!(Device, account_id: provider.account_id, uuid: uuid).sentinelone_id ==
             "225494730938493999"
  end

  test "deletes endpoints no completed run has seen for a day" do
    provider = sentinelone_posture_provider_fixture(synced_at: ago(2, :hour))
    stale = sentinelone_device_fixture(provider: provider, synced_at: ago(2, :day))
    stub_agents([agent(%{"id" => "225494730938493804"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    refute Repo.get_by(Device,
             account_id: provider.account_id,
             uuid: stale.uuid
           )
  end

  # Even a cursor is traversing a live collection. A single incomplete view is
  # not sufficient evidence that an endpoint was deleted at the source.
  test "keeps an endpoint a single run skipped over" do
    provider = sentinelone_posture_provider_fixture(synced_at: ago(2, :hour))
    skipped = sentinelone_device_fixture(provider: provider, synced_at: ago(3, :hour))
    stub_agents([agent(%{"id" => "225494730938493804"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device,
             account_id: provider.account_id,
             uuid: skipped.uuid
           )
  end

  test "keeps an endpoint skipped by the first successful run after a long outage" do
    outage = ago(30, :day)
    provider = sentinelone_posture_provider_fixture(synced_at: outage)
    skipped = sentinelone_device_fixture(provider: provider, synced_at: outage)
    stub_agents([agent(%{"id" => "225494730938493804"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device,
             account_id: provider.account_id,
             uuid: skipped.uuid
           )
  end

  test "deletes nothing on a provider's first run" do
    provider = sentinelone_posture_provider_fixture(synced_at: nil)
    ancient = sentinelone_device_fixture(provider: provider, synced_at: ago(30, :day))
    stub_agents([agent(%{"id" => "225494730938493804"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device,
             account_id: provider.account_id,
             uuid: ancient.uuid
           )
  end

  test "records success and clears earlier provider errors" do
    provider =
      sentinelone_posture_provider_fixture(
        errored_at: DateTime.utc_now(),
        error_message: "HTTP 503",
        error_email_count: 2
      )

    stub_agents([agent(%{"id" => "225494730938493804"})])
    assert :ok = perform_job(Sync, sync_args(provider))

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert provider.synced_at
    refute provider.errored_at
    refute provider.error_message
    assert provider.error_email_count == 0
  end

  test "skips a disabled provider" do
    provider = sentinelone_posture_provider_fixture(is_disabled: true)
    stub_agents([agent(%{"id" => "225494730938493804"})])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  defp sync_args(provider) do
    %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
  end

  defp ago(amount, unit) do
    DateTime.utc_now() |> DateTime.add(-amount, unit) |> DateTime.truncate(:microsecond)
  end

  defp stub_agents(agents) do
    Req.Test.stub(APIClient, fn conn ->
      Req.Test.json(conn, %{
        "data" => agents,
        "pagination" => %{"nextCursor" => nil, "totalItems" => length(agents)}
      })
    end)
  end

  defp agent(overrides) do
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
        overrides
      )

    Map.put_new(agent, "uuid", "agent-uuid-#{agent["id"]}")
  end

  # Every top-level property in SentinelOne's Management API v2.1
  # agents.schemas_AgentViewSchema_many_200 response schema.
  defp full_agent do
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
