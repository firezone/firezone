defmodule Portal.Repo.Migrations.MergeDuplicateDevicesTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.DeviceActorFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias Portal.{Device, DeviceActor, PolicyAuthorization, SiteDevice}

  Code.require_file("priv/repo/migrations/helpers/device_merge.exs")
  alias Portal.Repo.Migrations.DeviceMerge

  setup do
    account = account_fixture()
    %{account: account}
  end

  defp seen(device, seconds_ago) do
    record_last_seen(device, DateTime.add(DateTime.utc_now(), -seconds_ago, :second))
  end

  describe "groups/0" do
    test "keeps the row seen last and lists the rest", %{account: account} do
      older = client_fixture(account: account, firezone_id: "laptop") |> seen(600)
      newer = client_fixture(account: account, firezone_id: "laptop") |> seen(60)
      _other = client_fixture(account: account, firezone_id: "desktop")

      assert [group] = DeviceMerge.groups()
      assert group.account_id == account.id
      assert group.key == "laptop"
      assert group.winner.id == newer.id
      assert Enum.map(group.losers, & &1.id) == [older.id]
      refute group.mixed_types?
    end

    test "falls back to the creation time for rows never seen", %{account: account} do
      first = client_fixture(account: account, firezone_id: "laptop") |> record_last_seen(nil)
      second = client_fixture(account: account, firezone_id: "laptop") |> record_last_seen(nil)

      assert [group] = DeviceMerge.groups()
      assert group.winner.id == second.id
      assert Enum.map(group.losers, & &1.id) == [first.id]
    end

    test "flags a group mixing client and gateway rows", %{account: account} do
      client_fixture(account: account, firezone_id: "box")
      gateway_fixture(account: account, firezone_id: "box")

      assert [%{mixed_types?: true}] = DeviceMerge.groups()
    end

    test "groups attested rows by certificate", %{account: account} do
      for _ <- 1..2 do
        client_fixture(
          account: account,
          last_attested_cert_issuer: "issuer",
          last_attested_cert_serial: "AA",
          last_attested_cert_fingerprint: Ecto.UUID.generate(),
          last_attested_at: DateTime.utc_now()
        )
      end

      assert [group] = DeviceMerge.groups()
      assert group.key =~ "AA"
    end
  end

  describe "merge/1" do
    test "moves everything the losers had onto the winner and deletes them", %{account: account} do
      owner = actor_fixture(account: account)
      guest = actor_fixture(account: account)
      loser = client_fixture(account: account, actor: owner, firezone_id: "laptop") |> seen(600)
      winner = client_fixture(account: account, actor: guest, firezone_id: "laptop") |> seen(60)
      earlier = DateTime.add(DateTime.utc_now(), -86_400, :second)
      device_actor_fixture(device: loser, actor: owner, first_seen_at: earlier, last_seen_at: earlier)

      pool = device_pool_resource_fixture(account: account, devices: [loser])
      peer = client_fixture(account: account)

      authorization =
        policy_authorization_fixture(account: account, resource: pool, client: peer, gateway: loser)

      [group] = DeviceMerge.groups()
      assert :ok = DeviceMerge.merge(group)

      refute Repo.get_by(Device, account_id: account.id, id: loser.id)
      assert Repo.get_by(Device, account_id: account.id, id: winner.id)

      actor_rows =
        Repo.all(from(da in DeviceActor, where: da.device_id == ^winner.id, select: {da.actor_id, da.first_seen_at}))

      assert Enum.sort(Enum.map(actor_rows, &elem(&1, 0))) == Enum.sort([owner.id, guest.id])
      assert {_, first_seen_at} = Enum.find(actor_rows, &(elem(&1, 0) == owner.id))
      assert DateTime.compare(first_seen_at, earlier) == :eq

      assert Repo.get_by!(PolicyAuthorization, id: authorization.id).receiving_device_id == winner.id

      pool = Repo.get_by!(Portal.Resource, account_id: account.id, id: pool.id)
      assert {:ok, [winner.id]} == Portal.Resource.DeviceMembershipCriteria.device_ids(pool.device_membership_criteria)
    end

    test "merges gateways from two sites into one serving both", %{account: account} do
      site_a = site_fixture(account: account)
      site_b = site_fixture(account: account)
      loser = gateway_fixture(account: account, site: site_a, firezone_id: "gw") |> seen(600)
      winner = gateway_fixture(account: account, site: site_b, firezone_id: "gw") |> seen(60)

      [group] = DeviceMerge.groups()
      assert :ok = DeviceMerge.merge(group)

      site_ids =
        Repo.all(from(sd in SiteDevice, where: sd.device_id == ^winner.id, select: sd.site_id))

      assert Enum.sort(site_ids) == Enum.sort([site_a.id, site_b.id])
      refute Repo.get_by(Device, account_id: account.id, id: loser.id)
      assert Repo.get_by!(Device, account_id: account.id, id: winner.id).site_id == site_b.id
    end

    test "a bound token follows the machine when the winner has none", %{account: account} do
      loser =
        gateway_fixture(
          account: account,
          site: site_fixture(account: account),
          firezone_id: "gw",
          token: :single_owner
        )
        |> seen(600)

      winner =
        gateway_fixture(account: account, site: site_fixture(account: account), firezone_id: "gw")
        |> seen(60)

      token = Repo.get_by!(Portal.ClientToken, account_id: account.id, device_id: loser.id)

      [group] = DeviceMerge.groups()
      assert :ok = DeviceMerge.merge(group)

      assert Repo.get_by!(Portal.ClientToken, account_id: account.id, id: token.id).device_id ==
               winner.id
    end

    test "leaves a mixed group alone", %{account: account} do
      client = client_fixture(account: account, firezone_id: "box")
      gateway = gateway_fixture(account: account, firezone_id: "box")

      [group] = DeviceMerge.groups()
      assert :ok = DeviceMerge.merge(group)

      assert Repo.get_by(Device, account_id: account.id, id: client.id)
      assert Repo.get_by(Device, account_id: account.id, id: gateway.id)
    end
  end

  describe "merge_all/0" do
    test "merges every mergeable group and reports the skipped ones", %{account: account} do
      client_fixture(account: account, firezone_id: "laptop") |> seen(600)
      client_fixture(account: account, firezone_id: "laptop") |> seen(60)
      client_fixture(account: account, firezone_id: "box")
      gateway_fixture(account: account, firezone_id: "box")

      assert %{merged: [merged], skipped: [skipped]} = DeviceMerge.merge_all()
      assert merged.key == "laptop"
      assert skipped.key == "box"
      assert Repo.aggregate(from(d in Device, where: d.account_id == ^account.id), :count) == 3
    end
  end
end
