defmodule Portal.Defender.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.DevicePostureFixtures
  import Portal.DefenderFixtures

  alias Portal.Defender.{APIClient, Device, PostureProvider, Sync}

  setup do
    enable_device_posture()
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"error" => "not mocked"}) end)
    :ok
  end

  test "stores every machine in the tenant" do
    provider = defender_posture_provider_fixture()

    stub_machines([
      machine(%{
        "id" => "machine-1",
        "computerDnsName" => "alice.contoso.com"
      }),
      machine(%{
        "id" => "machine-2",
        "computerDnsName" => "bob.contoso.com",
        "healthStatus" => "Inactive"
      })
    ])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert [first, second] = Repo.all(from(d in Device, order_by: d.defender_id))

    assert first.defender_id == "machine-1"
    assert first.computer_dns_name == "alice.contoso.com"
    assert first.health_status == "Active"
    assert first.os_platform == "Windows11"
    assert first.account_id == provider.account_id
    assert first.posture_provider_id == provider.id

    assert second.defender_id == "machine-2"
    assert second.health_status == "Inactive"
  end

  test "stores every property the machines endpoint returns" do
    provider = defender_posture_provider_fixture()

    stub_machines([full_machine()])

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, defender_id: "1e5bc9d7e413ddd7902c2932e418702b84d0cc07")

    assert device.computer_dns_name == "mymachine1.contoso.com"
    assert device.first_seen_at == ~U[2018-08-02 14:55:03.779185Z]
    assert device.last_seen_at == ~U[2021-01-25 07:27:36.052313Z]
    assert device.os_platform == "Windows10"
    assert device.version == "1901"
    assert device.os_processor == "x64"
    assert device.os_architecture == "64-bit"
    assert device.os_build == 19_042
    assert device.last_ip_address == %Postgrex.INET{address: {10, 166, 113, 46}}
    assert device.last_external_ip_address == %Postgrex.INET{address: {167, 220, 203, 175}}
    assert device.agent_version == "10.8040.19041.4046"
    assert device.health_status == "Active"
    assert device.onboarding_status == "Onboarded"
    assert device.managed_by == "Intune"
    assert device.managed_by_status == "Managed"
    assert device.risk_score == "High"
    assert device.exposure_level == "Low"
    assert device.device_value == "Normal"
    assert device.rbac_group_name == "The-A-Team"
    assert device.rbac_group_id == 140
    assert device.entra_device_id == "fd2e4d29-7072-4195-aaa5-1af139b78028"
    assert device.entra_joined == true
    assert device.machine_tags == ["Tag1", "Tag2"]
    assert device.is_potential_duplication == false
    assert device.is_excluded == false
    refute device.exclusion_reason
    assert device.merged_into_machine_id == "merged-machine-id"
    assert device.vm_id == "vm-id-value"
    assert device.vm_cloud_provider == "Azure"
    assert device.vm_resource_id == "/subscriptions/sub-id/resourceGroups/rg/vm"
    assert device.vm_subscription_id == "sub-id"

    assert device.ip_addresses == [
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
           ]
  end

  # The entity types rbacGroupId as Int32 while the reference table calls it a
  # String, so the column has to take either.
  test "stores a numeric device group id as text" do
    provider = defender_posture_provider_fixture()

    stub_machines([machine(%{"rbacGroupId" => 140})])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by!(Device, defender_id: "machine-1").rbac_group_id == 140
  end

  # The endpoint sends no next link, so a full page is the only signal that more
  # machines are waiting. Stopping after the first page would make the run treat
  # every machine it never asked for as gone and delete it.
  test "walks $skip until a short page ends the tenant" do
    provider = defender_posture_provider_fixture()

    machines =
      Enum.map(1..1001, fn n ->
        machine(%{"id" => "machine-#{String.pad_leading(to_string(n), 4, "0")}"})
      end)

    stub_machines(machines)

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.aggregate(Device, :count) == 1001
    assert Repo.get_by(Device, account_id: provider.account_id, defender_id: "machine-1001")
  end

  test "asks for a page at a time" do
    provider = defender_posture_provider_fixture()
    test_pid = self()

    Req.Test.stub(APIClient, fn conn ->
      if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
        Req.Test.json(conn, %{"access_token" => "defender-token"})
      else
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:page, conn.query_params["$top"], conn.query_params["$skip"]})
        Req.Test.json(conn, %{"value" => [machine(%{"id" => "machine-1"})]})
      end
    end)

    assert :ok = perform_job(Sync, sync_args(provider))

    assert_received {:page, "1000", "0"}
  end

  test "raises when the tenant refuses the machine list" do
    provider = defender_posture_provider_fixture()

    Req.Test.stub(APIClient, fn conn ->
      if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
        Req.Test.json(conn, %{"access_token" => "defender-token"})
      else
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => %{"code" => "Forbidden"}})
      end
    end)

    assert_raise Portal.Defender.SyncError, fn -> perform_job(Sync, sync_args(provider)) end
  end

  test "raises when the token endpoint refuses the app" do
    provider = defender_posture_provider_fixture()

    Req.Test.stub(APIClient, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error_description" => "AADSTS7000215: Invalid client secret."})
    end)

    assert_raise Portal.Defender.SyncError, fn -> perform_job(Sync, sync_args(provider)) end
  end

  test "raises when a machine comes back without an id" do
    provider = defender_posture_provider_fixture()

    stub_machines([machine(%{"id" => nil})])

    assert_raise Portal.Defender.SyncError, fn -> perform_job(Sync, sync_args(provider)) end
  end

  test "raises when the response has no value key" do
    provider = defender_posture_provider_fixture()

    Req.Test.stub(APIClient, fn conn ->
      if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
        Req.Test.json(conn, %{"access_token" => "defender-token"})
      else
        Req.Test.json(conn, %{"machines" => []})
      end
    end)

    assert_raise Portal.Defender.SyncError, fn -> perform_job(Sync, sync_args(provider)) end
  end

  test "deletes machines no run has seen for a day" do
    provider = defender_posture_provider_fixture(synced_at: ago(2, :hour))
    stale = defender_device_fixture(provider: provider, synced_at: ago(2, :day))

    stub_machines([machine(%{"id" => "machine-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    refute Repo.get_by(Device, account_id: provider.account_id, defender_id: stale.defender_id)
    assert Repo.get_by(Device, account_id: provider.account_id, defender_id: "machine-1")
  end

  # `$skip` steps over a machine whenever the tenant loses one mid-walk, so one
  # run missing a machine has to leave it alone. Deleting it here would drop the
  # row on one run and write it back on the next, every couple of hours.
  test "keeps a machine a single run skipped over" do
    provider = defender_posture_provider_fixture(synced_at: ago(2, :hour))
    skipped = defender_device_fixture(provider: provider, synced_at: ago(3, :hour))

    stub_machines([machine(%{"id" => "machine-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device, account_id: provider.account_id, defender_id: skipped.defender_id)
  end

  # Once syncing has been broken for longer than the window, every row is past
  # the clock, and measuring from it alone would let one walk empty the tenant.
  test "keeps a machine skipped by the first run after a long outage" do
    outage = ago(30, :day)
    provider = defender_posture_provider_fixture(synced_at: outage)
    skipped = defender_device_fixture(provider: provider, synced_at: outage)

    stub_machines([machine(%{"id" => "machine-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device, account_id: provider.account_id, defender_id: skipped.defender_id)
  end

  test "deletes nothing on the first run of a provider" do
    provider = defender_posture_provider_fixture(synced_at: nil)
    ancient = defender_device_fixture(provider: provider, synced_at: ago(30, :day))

    stub_machines([machine(%{"id" => "machine-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device, account_id: provider.account_id, defender_id: ancient.defender_id)
  end

  test "records the sync and clears earlier errors on the provider" do
    provider =
      defender_posture_provider_fixture(
        errored_at: DateTime.utc_now(),
        error_message: "HTTP 403",
        error_email_count: 2
      )

    stub_machines([machine(%{"id" => "machine-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)

    assert provider.synced_at
    refute provider.errored_at
    refute provider.error_message
    assert provider.error_email_count == 0
  end

  test "skips a disabled provider" do
    provider = defender_posture_provider_fixture(is_disabled: true)

    stub_machines([machine(%{"id" => "machine-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  test "skips a provider whose account lost the device_posture feature" do
    downgraded = Portal.AccountFixtures.account_fixture(features: %{device_posture: false})
    provider = defender_posture_provider_fixture(account: downgraded)

    stub_machines([machine(%{"id" => "machine-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  test "skips every provider when the global flag is off" do
    provider = defender_posture_provider_fixture()
    enable_device_posture(false)

    stub_machines([machine(%{"id" => "machine-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  defp sync_args(provider) do
    %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
  end

  defp ago(amount, unit) do
    DateTime.utc_now() |> DateTime.add(-amount, unit) |> DateTime.truncate(:microsecond)
  end

  defp stub_machines(machines) do
    Req.Test.stub(APIClient, fn conn ->
      if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
        Req.Test.json(conn, %{"access_token" => "defender-token"})
      else
        conn = Plug.Conn.fetch_query_params(conn)
        top = String.to_integer(conn.query_params["$top"] || "1000")
        skip = String.to_integer(conn.query_params["$skip"] || "0")

        Req.Test.json(conn, %{"value" => Enum.slice(machines, skip, top)})
      end
    end)
  end

  defp machine(overrides) do
    Map.merge(
      %{
        "id" => "machine-1",
        "computerDnsName" => "alice.contoso.com",
        "osPlatform" => "Windows11",
        "healthStatus" => "Active",
        "onboardingStatus" => "Onboarded",
        "riskScore" => "Low"
      },
      overrides
    )
  end

  # The example response from the List machines reference, so the mapping can be
  # checked against the documented payload.
  defp full_machine do
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
