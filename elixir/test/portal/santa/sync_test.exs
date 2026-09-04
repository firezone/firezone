defmodule Portal.Santa.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.DevicePostureFixtures
  import Portal.SantaFixtures

  alias Portal.Santa.{APIClient, Device, PostureProvider, Sync}

  setup do
    enable_device_posture()
    stub_api([])
    :ok
  end

  test "stores the macOS Host inventory returned by Workshop" do
    provider = santa_posture_provider_fixture()

    stub_api([
      host(%{
        "uuid" => "host-1",
        "hostname" => "alices-macbook",
        "serial" => "FVHHFKF7Q6L4"
      })
    ])

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, santa_id: "host-1")
    assert device.hostname == "alices-macbook"
    assert device.serial_number == "FVHHFKF7Q6L4"
    assert device.machine_model == "MacBookPro18,3"
    assert device.os_version == "15.6"
    assert device.os_build == "24G84"
    assert device.os_type == "OS_TYPE_MACOS"
    assert device.sip_status == 1
    assert device.primary_user == "alice@example.com"
    assert device.primary_user_locked
    assert device.primary_user_groups == ["engineering", "admins"]
    assert device.santa_version == "2026.7"
    assert device.santanetd_version == "2026.7.1"
    assert device.last_seen_client_mode == "LOCKDOWN"
    assert device.last_sync_at == ~U[2026-08-26 18:10:00.123456Z]
    assert device.rule_sync_at == ~U[2026-08-26 18:09:00.000000Z]
    assert device.last_preflight_at == ~U[2026-08-26 18:08:00.000000Z]
    assert device.last_preflight_ip == %Postgrex.INET{address: {192, 168, 1, 1}}
    assert device.tags == ["global", "production"]
    assert device.tags_locked
    refute device.tags_truncated
    assert device.configured_client_mode == "LOCKDOWN"
    assert device.temporary_monitor_mode_ends_at == ~U[2026-08-27 18:00:00.000000Z]
    assert device.first_seen_at == ~U[2026-01-02 03:04:05.000000Z]
    assert device.temporary_admin_mode_ends_at == ~U[2026-08-26 19:00:00.000000Z]
    assert device.temporary_admin_mode_user == "alice"
    assert device.account_id == provider.account_id
    assert device.posture_provider_id == provider.id
  end

  test "stores Linux inventory using the shared Workshop Host schema" do
    provider = santa_posture_provider_fixture()

    stub_api([
      %{
        "uuid" => "linux-host-1",
        "hostname" => "build-runner",
        "machineModel" => "x86_64",
        "osVersion" => "6.10.14",
        "osBuild" => "6.10.14-arch1-1",
        "osType" => "OS_TYPE_LINUX",
        "primaryUser" => "builder",
        "santaVersion" => "2026.8",
        "lastSync" => "2026-08-26T18:10:00Z"
      }
    ])

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, santa_id: "linux-host-1")
    assert device.hostname == "build-runner"
    assert device.machine_model == "x86_64"
    assert device.os_version == "6.10.14"
    assert device.os_build == "6.10.14-arch1-1"
    assert device.os_type == "OS_TYPE_LINUX"
    assert device.primary_user == "builder"
    assert device.santa_version == "2026.8"
    assert device.last_sync_at == ~U[2026-08-26 18:10:00.000000Z]
    assert is_nil(device.sip_status)
    refute device.primary_user_locked
  end

  test "reads fields ProtoJSON omits at their default values" do
    provider = santa_posture_provider_fixture()

    stub_api([
      %{
        "uuid" => "quiet-mac",
        "hostname" => "quiet-mac",
        "osType" => "OS_TYPE_MACOS",
        "lastPreflightIp" => Base.encode64(<<0x2001::16, 0xDB8::16, 0::16, 0::16, 0::16, 0::16, 0::16, 1::16>>)
      }
    ])

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, santa_id: "quiet-mac")
    assert device.sip_status == 0
    refute device.primary_user_locked
    refute device.tags_locked
    refute device.tags_truncated
    assert device.last_preflight_ip == %Postgrex.INET{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}}
  end

  test "uses the Workshop ConnectRPC pagination and authorization contract" do
    provider = santa_posture_provider_fixture(api_key: "npsws_sk_secret")
    parent = self()

    Req.Test.stub(APIClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      request = Jason.decode!(conn.query_params["message"])
      send(parent, {:request, conn.request_path, conn.query_params["encoding"], request})

      assert Plug.Conn.get_req_header(conn, "authorization") == ["npsws_sk_secret"]

      case request["page"] do
        1 -> Req.Test.json(conn, %{"hosts" => [host(%{"uuid" => "first"})], "more" => true})
        2 -> Req.Test.json(conn, %{"hosts" => [host(%{"uuid" => "second"})], "more" => false})
      end
    end)

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 2

    assert_received {:request, "/workshop.v1.WorkshopService/ListHosts", "json",
                     %{"orderBy" => "uuid", "page" => 1, "pageSize" => 100}}

    assert_received {:request, "/workshop.v1.WorkshopService/ListHosts", "json",
                     %{"orderBy" => "uuid", "page" => 2, "pageSize" => 100}}
  end

  test "scopes reported host IDs to the Workshop posture provider" do
    account = device_posture_account_fixture()
    first_provider = santa_posture_provider_fixture(account: account)
    second_provider = santa_posture_provider_fixture(account: account)

    stub_api([host(%{"uuid" => "shared-machine-id", "hostname" => "first-tenant-host"})])
    assert :ok = perform_job(Sync, sync_args(first_provider))

    stub_api([host(%{"uuid" => "shared-machine-id", "hostname" => "second-tenant-host"})])
    assert :ok = perform_job(Sync, sync_args(second_provider))

    devices =
      Device
      |> where([d], d.account_id == ^account.id and d.santa_id == "shared-machine-id")
      |> order_by([d], asc: d.hostname)
      |> Repo.all()

    assert Enum.map(devices, &{&1.posture_provider_id, &1.hostname}) == [
             {first_provider.id, "first-tenant-host"},
             {second_provider.id, "second-tenant-host"}
           ]
  end

  test "accepts proto JSON that omits an empty hosts collection" do
    provider = santa_posture_provider_fixture()
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{}) end)

    assert :ok = APIClient.test_connection(APIClient.new(provider))
    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  test "deletes hosts no completed run has seen for a day and clears provider errors" do
    provider =
      santa_posture_provider_fixture(
        synced_at: ago(2, :hour),
        errored_at: DateTime.utc_now(),
        error_message: "old error",
        error_email_count: 2
      )

    stale =
      santa_device_fixture(
        provider: provider,
        santa_id: "stale",
        synced_at: ago(2, :day)
      )

    stub_api([host(%{"uuid" => "current"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    refute Repo.get_by(Device, account_id: provider.account_id, santa_id: stale.santa_id)
    assert Repo.get_by(Device, account_id: provider.account_id, santa_id: "current")

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert provider.synced_at
    refute provider.errored_at
    refute provider.error_message
    assert provider.error_email_count == 0
  end

  test "keeps a host skipped by one paginated walk" do
    provider = santa_posture_provider_fixture(synced_at: ago(2, :hour))

    skipped =
      santa_device_fixture(
        provider: provider,
        santa_id: "skipped",
        synced_at: ago(3, :hour)
      )

    stub_api([host(%{"uuid" => "current"})])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.get_by(Device, account_id: provider.account_id, santa_id: skipped.santa_id)
  end

  test "keeps a host skipped by the first successful run after a long outage" do
    outage = ago(30, :day)
    provider = santa_posture_provider_fixture(synced_at: outage)

    skipped =
      santa_device_fixture(
        provider: provider,
        santa_id: "skipped",
        synced_at: outage
      )

    stub_api([host(%{"uuid" => "current"})])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.get_by(Device, account_id: provider.account_id, santa_id: skipped.santa_id)
  end

  test "deletes nothing on a provider's first sync" do
    provider = santa_posture_provider_fixture(synced_at: nil)

    ancient =
      santa_device_fixture(
        provider: provider,
        santa_id: "ancient",
        synced_at: ago(30, :day)
      )

    stub_api([host(%{"uuid" => "current"})])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.get_by(Device, account_id: provider.account_id, santa_id: ancient.santa_id)
  end

  test "deletes nothing when a later page fails" do
    provider = santa_posture_provider_fixture(synced_at: ago(2, :hour))

    stale =
      santa_device_fixture(
        provider: provider,
        santa_id: "stale",
        synced_at: ago(2, :day)
      )

    Req.Test.stub(APIClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      request = Jason.decode!(conn.query_params["message"])

      case request["page"] do
        1 -> Req.Test.json(conn, %{"hosts" => [host(%{"uuid" => "first"})], "more" => true})
        2 -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"message" => "unavailable"})
      end
    end)

    assert_raise Portal.Santa.SyncError, fn -> perform_job(Sync, sync_args(provider)) end
    assert Repo.get_by(Device, account_id: provider.account_id, santa_id: stale.santa_id)
  end

  test "raises when Workshop refuses the request or omits a host id" do
    refused_provider = santa_posture_provider_fixture()

    Req.Test.stub(APIClient, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "invalid key"})
    end)

    assert_raise Portal.Santa.SyncError, fn ->
      perform_job(Sync, sync_args(refused_provider))
    end

    invalid_provider = santa_posture_provider_fixture()
    stub_api([host(%{"uuid" => nil})])

    assert_raise Portal.Santa.SyncError, fn ->
      perform_job(Sync, sync_args(invalid_provider))
    end
  end

  test "skips disabled providers and all providers when the feature is off" do
    disabled = santa_posture_provider_fixture(is_disabled: true)
    enabled = santa_posture_provider_fixture()
    stub_api([host(%{"uuid" => "host-1"})])

    assert :ok = perform_job(Sync, sync_args(disabled))
    assert Repo.aggregate(Device, :count) == 0

    enable_device_posture(false)
    assert :ok = perform_job(Sync, sync_args(enabled))
    assert Repo.aggregate(Device, :count) == 0
  end

  defp ago(amount, unit) do
    DateTime.utc_now() |> DateTime.add(-amount, unit) |> DateTime.truncate(:microsecond)
  end

  defp sync_args(provider) do
    %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
  end

  defp host(overrides) do
    Map.merge(
      %{
        "uuid" => "host-1",
        "serial" => "SERIAL-1",
        "machineModel" => "MacBookPro18,3",
        "hostname" => "macbook",
        "osVersion" => "15.6",
        "osBuild" => "24G84",
        "osType" => "OS_TYPE_MACOS",
        "sipStatus" => 1,
        "primaryUser" => "alice@example.com",
        "primaryUserLocked" => true,
        "primaryUserGroups" => ["engineering", "admins"],
        "santaVersion" => "2026.7",
        "santanetdVersion" => "2026.7.1",
        "lastSeenClientMode" => "LOCKDOWN",
        "lastSync" => "2026-08-26T18:10:00.123456Z",
        "ruleSyncTime" => "2026-08-26T18:09:00Z",
        "lastPreflightTime" => "2026-08-26T18:08:00Z",
        "lastPreflightIp" => "wKgBAQ==",
        "tags" => ["global", "production"],
        "tagsLocked" => true,
        "tagsTruncated" => false,
        "configuredClientMode" => "LOCKDOWN",
        "temporaryMonitorModeEndTime" => "2026-08-27T18:00:00Z",
        "createdAt" => "2026-01-02T03:04:05Z",
        "temporaryAdminModeEndTime" => "2026-08-26T19:00:00Z",
        "temporaryAdminModeUser" => "alice"
      },
      overrides
    )
  end

  defp stub_api(hosts) do
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"hosts" => hosts, "more" => false}) end)
  end
end
