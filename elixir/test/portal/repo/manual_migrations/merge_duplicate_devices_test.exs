defmodule Portal.Repo.Migrations.MergeDuplicateDevicesTest do
  # Rows sharing a key cannot be created once the account-wide identity
  # indexes exist, so the grouping is tested on synthetic rows and the merge
  # on groups built by hand from distinct devices.
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

  defp row(attrs) do
    Map.merge(%{id: Ecto.UUID.generate(), slug: "slug", type: "client", seen_at: ~U[2026-10-01 00:00:00Z]}, Map.new(attrs))
  end

  defp group(account, winner, losers) do
    %{
      account_id: account.id,
      key: "key",
      winner: %{id: winner.id, slug: winner.slug, type: to_string(winner.type)},
      losers: Enum.map(losers, &%{id: &1.id, slug: &1.slug, type: to_string(&1.type)}),
      mixed_types?: false
    }
  end

  describe "to_group/1" do
    test "keeps the row seen last and lists the rest" do
      older = row(seen_at: ~U[2026-10-01 00:00:00Z])
      newer = row(seen_at: ~U[2026-10-02 00:00:00Z])

      group = DeviceMerge.to_group(%{account_id: Ecto.UUID.generate(), key: "laptop", rows: [older, newer]})

      assert group.winner.id == newer.id
      assert Enum.map(group.losers, & &1.id) == [older.id]
      refute group.mixed_types?
    end

    test "breaks a tie on the id so the choice is stable" do
      seen_at = ~U[2026-10-01 00:00:00Z]
      low = row(id: "00000000-0000-0000-0000-000000000001", seen_at: seen_at)
      high = row(id: "00000000-0000-0000-0000-000000000002", seen_at: seen_at)

      group = DeviceMerge.to_group(%{account_id: Ecto.UUID.generate(), key: "k", rows: [high, low]})

      assert group.winner.id == low.id
    end

    test "flags a group mixing client and gateway rows" do
      rows = [row(type: "client"), row(type: "gateway")]

      assert %{mixed_types?: true} =
               DeviceMerge.to_group(%{account_id: Ecto.UUID.generate(), key: "box", rows: rows})
    end
  end

  describe "groups/0" do
    test "is empty when no two rows share a key", %{account: account} do
      client_fixture(account: account, firezone_id: "laptop")
      client_fixture(account: account, firezone_id: "desktop")

      assert DeviceMerge.groups() == []
    end
  end

  describe "merge/1" do
    test "moves everything the losers had onto the winner and deletes them", %{account: account} do
      owner = actor_fixture(account: account)
      guest = actor_fixture(account: account)
      loser = client_fixture(account: account, actor: owner)
      winner = client_fixture(account: account, actor: guest)
      earlier = DateTime.add(DateTime.utc_now(), -86_400, :second)
      device_actor_fixture(device: loser, actor: owner, first_seen_at: earlier, last_seen_at: earlier)

      pool = device_pool_resource_fixture(account: account, devices: [loser])
      peer = client_fixture(account: account)

      authorization =
        policy_authorization_fixture(account: account, resource: pool, client: peer, gateway: loser)

      assert :ok = DeviceMerge.merge(group(account, winner, [loser]))

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
      loser = gateway_fixture(account: account, site: site_a)
      winner = gateway_fixture(account: account, site: site_b)

      assert :ok = DeviceMerge.merge(group(account, winner, [loser]))

      site_ids =
        Repo.all(from(sd in SiteDevice, where: sd.device_id == ^winner.id, select: sd.site_id))

      assert Enum.sort(site_ids) == Enum.sort([site_a.id, site_b.id])
      refute Repo.get_by(Device, account_id: account.id, id: loser.id)
      assert Repo.get_by!(Device, account_id: account.id, id: winner.id).site_id == site_b.id
    end

    test "a bound token follows the machine when the winner has none", %{account: account} do
      loser =
        gateway_fixture(account: account, site: site_fixture(account: account), token: :single_owner)

      winner = gateway_fixture(account: account, site: site_fixture(account: account))
      token = Repo.get_by!(Portal.ClientToken, account_id: account.id, device_id: loser.id)

      assert :ok = DeviceMerge.merge(group(account, winner, [loser]))

      assert Repo.get_by!(Portal.ClientToken, account_id: account.id, id: token.id).device_id ==
               winner.id
    end

    test "leaves a mixed group alone", %{account: account} do
      client = client_fixture(account: account)
      gateway = gateway_fixture(account: account)

      assert :ok = DeviceMerge.merge(%{group(account, client, [gateway]) | mixed_types?: true})

      assert Repo.get_by(Device, account_id: account.id, id: client.id)
      assert Repo.get_by(Device, account_id: account.id, id: gateway.id)
    end
  end

  describe "merge_all/0" do
    test "has nothing to do without duplicates", %{account: account} do
      client_fixture(account: account)

      assert %{merged: [], skipped: []} = DeviceMerge.merge_all()
    end
  end
end
