defmodule Portal.DevicePool.CacheTest do
  use Portal.DataCase, async: true, group: :client_queues

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.ResourceFixtures
  import Portal.SubjectFixtures

  alias Portal.Cache.Cacheable
  alias Portal.Changes.Change
  alias Portal.DevicePool.Bitmap
  alias Portal.DevicePool.Cache
  alias Portal.PubSub
  alias Portal.Resource.DeviceMembershipCriteria

  setup do
    start_supervised!({Cache, callers: [self()]})

    account = account_fixture()
    actor = actor_fixture(account: account)
    subject = subject_fixture(account: account, actor: actor, type: :client)

    %{account: account, actor: actor, subject: subject}
  end

  describe "members/2" do
    test "computes a listed pool on first use", %{account: account, subject: subject} do
      first = client_fixture(account: account) |> fetch_device!()
      second = client_fixture(account: account) |> fetch_device!()
      client_fixture(account: account)
      pool = device_pool_resource_fixture(account: account, devices: [first, second])

      members = Bitmap.encode_devices([first, second])

      assert Cache.members(Cacheable.to_cache(pool), subject) == %{version: 1, members: members}

      assert [{{_, _, :all}, %{version: 1, members: ^members, sets: sets}}] =
               :ets.lookup(:device_pool_bitmaps, {account.id, pool.id, :all})

      assert sets == Bitmap.sets([first, second])
    end

    test "computes an own-devices pool for the subject's actor", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      own = client_fixture(account: account, actor: actor) |> fetch_device!()
      client_fixture(account: account, actor: actor_fixture(account: account))
      pool = own_devices_pool_resource_fixture(account: account)

      members = Bitmap.encode_devices([own])
      actor_id = actor.id

      assert Cache.members(Cacheable.to_cache(pool), subject) == %{version: 1, members: members}

      assert [{{_, _, {:actor, ^actor_id}}, %{version: 1, members: ^members}}] =
               :ets.lookup(:device_pool_bitmaps, {account.id, pool.id, {:actor, actor_id}})
    end

    test "computes an all-devices pool once for everyone", %{account: account, actor: actor, subject: subject} do
      own = client_fixture(account: account, actor: actor) |> fetch_device!()
      other = client_fixture(account: account) |> fetch_device!()
      client_fixture(account: account_fixture())
      pool = all_devices_pool_resource_fixture(account: account)

      members = Bitmap.encode_devices([own, other])

      assert Cache.members(Cacheable.to_cache(pool), subject) == %{version: 1, members: members}
      assert [{{_, _, :all}, _}] = :ets.lookup(:device_pool_bitmaps, {account.id, pool.id, :all})
    end

    test "computes a group pool from the actors' memberships", %{account: account, actor: actor, subject: subject} do
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)
      own = client_fixture(account: account, actor: actor) |> fetch_device!()
      client_fixture(account: account)
      pool = actor_group_pool_resource_fixture(account: account, group: group)

      members = Bitmap.encode_devices([own])

      assert Cache.members(Cacheable.to_cache(pool), subject) == %{version: 1, members: members}
      assert [{{_, _, :all}, _}] = :ets.lookup(:device_pool_bitmaps, {account.id, pool.id, :all})
    end

    test "reads the table on later calls", %{account: account, actor: actor, subject: subject} do
      own = client_fixture(account: account, actor: actor) |> fetch_device!()
      pool = own_devices_pool_resource_fixture(account: account)
      cacheable = Cacheable.to_cache(pool)

      entry = Cache.members(cacheable, subject)
      client_fixture(account: account, actor: actor)

      assert Cache.members(cacheable, subject) == entry
      assert entry == %{version: 1, members: Bitmap.encode_devices([own])}
    end
  end

  describe "change handling" do
    test "recomputes the actor's own-devices pool when one of their devices appears", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      own = client_fixture(account: account, actor: actor) |> fetch_device!()
      pool = own_devices_pool_resource_fixture(account: account)
      :ok = Cache.subscribe(account.id)
      Cache.members(Cacheable.to_cache(pool), subject)

      added = client_fixture(account: account, actor: actor) |> fetch_device!()
      :ok = PubSub.Changes.broadcast(account.id, :devices, %Change{lsn: 1, op: :insert, struct: added})

      pool_id = pool.id
      actor_id = actor.id
      members = Bitmap.encode_devices([own, added])
      added_members = Bitmap.encode_devices([added])
      nothing = Bitmap.encode_devices([])

      assert_receive {:device_pool_members_updated, ^pool_id, {:actor, ^actor_id},
                      %{
                        version: 2,
                        previous: 1,
                        members: ^members,
                        added: ^added_members,
                        removed: ^nothing
                      }}

      assert Cache.members(Cacheable.to_cache(pool), subject) == %{version: 2, members: members}

      stranger =
        client_fixture(account: account, actor: actor_fixture(account: account)) |> fetch_device!()

      :ok = PubSub.Changes.broadcast(account.id, :devices, %Change{lsn: 2, op: :insert, struct: stranger})

      refute_receive {:device_pool_members_updated, _, _, _}
      assert Cache.members(Cacheable.to_cache(pool), subject) == %{version: 2, members: members}
    end

    test "leaves the version alone when a change does not move the set", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      own = client_fixture(account: account, actor: actor) |> fetch_device!()
      pool = own_devices_pool_resource_fixture(account: account)
      :ok = Cache.subscribe(account.id)
      entry = Cache.members(Cacheable.to_cache(pool), subject)

      never = client_fixture(account: account, actor: actor) |> fetch_device!()
      Repo.delete!(never)
      :ok = PubSub.Changes.broadcast(account.id, :devices, %Change{lsn: 1, op: :delete, old_struct: never})

      refute_receive {:device_pool_members_updated, _, _, _}
      assert Cache.members(Cacheable.to_cache(pool), subject) == entry
      assert entry == %{version: 1, members: Bitmap.encode_devices([own])}
    end

    test "recomputes the actor's own-devices pool when one of their devices goes away", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      own = client_fixture(account: account, actor: actor) |> fetch_device!()
      gone = client_fixture(account: account, actor: actor) |> fetch_device!()
      pool = own_devices_pool_resource_fixture(account: account)
      :ok = Cache.subscribe(account.id)
      Cache.members(Cacheable.to_cache(pool), subject)

      Repo.delete!(gone)
      :ok = PubSub.Changes.broadcast(account.id, :devices, %Change{lsn: 1, op: :delete, old_struct: gone})

      pool_id = pool.id
      members = Bitmap.encode_devices([own])
      removed = Bitmap.encode_devices([gone])
      nothing = Bitmap.encode_devices([])

      assert_receive {:device_pool_members_updated, ^pool_id, {:actor, _},
                      %{version: 2, previous: 1, members: ^members, added: ^nothing, removed: ^removed}}
    end

    test "recomputes an all-devices pool when any device appears or goes away", %{
      account: account,
      subject: subject
    } do
      first = client_fixture(account: account) |> fetch_device!()
      pool = all_devices_pool_resource_fixture(account: account)
      :ok = Cache.subscribe(account.id)
      Cache.members(Cacheable.to_cache(pool), subject)

      second = client_fixture(account: account) |> fetch_device!()
      :ok = PubSub.Changes.broadcast(account.id, :devices, %Change{lsn: 1, op: :insert, struct: second})

      pool_id = pool.id
      both = Bitmap.encode_devices([first, second])
      only_second = Bitmap.encode_devices([second])
      only_first = Bitmap.encode_devices([first])
      nothing = Bitmap.encode_devices([])

      assert_receive {:device_pool_members_updated, ^pool_id, :all,
                      %{version: 2, previous: 1, members: ^both, added: ^only_second, removed: ^nothing}}

      Repo.delete!(second)
      :ok = PubSub.Changes.broadcast(account.id, :devices, %Change{lsn: 2, op: :delete, old_struct: second})

      assert_receive {:device_pool_members_updated, ^pool_id, :all,
                      %{version: 3, previous: 2, members: ^only_first, added: ^nothing, removed: ^only_second}}

      assert Cache.members(Cacheable.to_cache(pool), subject) == %{version: 3, members: only_first}
    end

    test "recomputes a listed pool when a listed device goes away", %{account: account, subject: subject} do
      kept = client_fixture(account: account) |> fetch_device!()
      gone = client_fixture(account: account) |> fetch_device!()
      pool = device_pool_resource_fixture(account: account, devices: [kept, gone])
      :ok = Cache.subscribe(account.id)
      Cache.members(Cacheable.to_cache(pool), subject)

      unlisted = client_fixture(account: account) |> fetch_device!()
      :ok = PubSub.Changes.broadcast(account.id, :devices, %Change{lsn: 1, op: :insert, struct: unlisted})
      refute_receive {:device_pool_members_updated, _, _, _}

      Repo.delete!(gone)
      :ok = PubSub.Changes.broadcast(account.id, :devices, %Change{lsn: 2, op: :delete, old_struct: gone})

      pool_id = pool.id
      members = Bitmap.encode_devices([kept])
      removed = Bitmap.encode_devices([gone])
      nothing = Bitmap.encode_devices([])

      assert_receive {:device_pool_members_updated, ^pool_id, :all,
                      %{version: 2, previous: 1, members: ^members, added: ^nothing, removed: ^removed}}
    end

    test "recomputes a group pool when an actor joins or leaves the group", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      group = group_fixture(account: account)
      own = client_fixture(account: account, actor: actor) |> fetch_device!()
      pool = actor_group_pool_resource_fixture(account: account, group: group)
      :ok = Cache.subscribe(account.id)
      assert Cache.members(Cacheable.to_cache(pool), subject) == %{version: 1, members: Bitmap.encode_devices([])}

      membership = membership_fixture(account: account, actor: actor, group: group)
      :ok = PubSub.Changes.broadcast(account.id, :memberships, %Change{lsn: 1, op: :insert, struct: membership})

      pool_id = pool.id
      members = Bitmap.encode_devices([own])
      nothing = Bitmap.encode_devices([])

      assert_receive {:device_pool_members_updated, ^pool_id, :all,
                      %{version: 2, previous: 1, members: ^members, added: ^members, removed: ^nothing}}

      elsewhere = membership_fixture(account: account, actor: actor, group: group_fixture(account: account))
      :ok = PubSub.Changes.broadcast(account.id, :memberships, %Change{lsn: 2, op: :insert, struct: elsewhere})
      refute_receive {:device_pool_members_updated, _, _, _}

      Repo.delete!(membership)
      :ok = PubSub.Changes.broadcast(account.id, :memberships, %Change{lsn: 3, op: :delete, old_struct: membership})

      assert_receive {:device_pool_members_updated, ^pool_id, :all,
                      %{version: 3, previous: 2, members: ^nothing, added: ^nothing, removed: ^members}}
    end

    test "recomputes a group pool when a member's device appears", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)
      pool = actor_group_pool_resource_fixture(account: account, group: group)
      :ok = Cache.subscribe(account.id)
      Cache.members(Cacheable.to_cache(pool), subject)

      added = client_fixture(account: account, actor: actor) |> fetch_device!()
      :ok = PubSub.Changes.broadcast(account.id, :devices, %Change{lsn: 1, op: :insert, struct: added})

      pool_id = pool.id
      members = Bitmap.encode_devices([added])
      nothing = Bitmap.encode_devices([])

      assert_receive {:device_pool_members_updated, ^pool_id, :all,
                      %{version: 2, previous: 1, members: ^members, added: ^members, removed: ^nothing}}
    end

    test "recomputes a pool whose criteria change kind but not scope", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)
      in_group = client_fixture(account: account, actor: actor) |> fetch_device!()
      listed = client_fixture(account: account) |> fetch_device!()
      pool = device_pool_resource_fixture(account: account, devices: [listed])
      :ok = Cache.subscribe(account.id)
      Cache.members(Cacheable.to_cache(pool), subject)

      all = %{pool | device_membership_criteria: DeviceMembershipCriteria.all_devices()}
      :ok = PubSub.Changes.broadcast(account.id, :resources, %Change{lsn: 1, op: :update, old_struct: pool, struct: all})

      pool_id = pool.id
      everyone = Bitmap.encode_devices([in_group, listed])
      only_in_group = Bitmap.encode_devices([in_group])
      only_listed = Bitmap.encode_devices([listed])
      nothing = Bitmap.encode_devices([])

      assert_receive {:device_pool_members_updated, ^pool_id, :all,
                      %{version: 2, previous: 1, members: ^everyone, added: ^only_in_group, removed: ^nothing}}

      grouped = %{pool | device_membership_criteria: DeviceMembershipCriteria.actor_group(group.id)}
      :ok = PubSub.Changes.broadcast(account.id, :resources, %Change{lsn: 2, op: :update, old_struct: all, struct: grouped})

      assert_receive {:device_pool_members_updated, ^pool_id, :all,
                      %{version: 3, previous: 2, members: ^only_in_group, added: ^nothing, removed: ^only_listed}}

      assert Cache.members(Cacheable.to_cache(grouped), subject) == %{version: 3, members: only_in_group}
    end

    test "recomputes a listed pool when its criteria change", %{account: account, subject: subject} do
      first = client_fixture(account: account) |> fetch_device!()
      second = client_fixture(account: account) |> fetch_device!()
      pool = device_pool_resource_fixture(account: account, devices: [first, second])
      :ok = Cache.subscribe(account.id)
      Cache.members(Cacheable.to_cache(pool), subject)

      updated = %{pool | device_membership_criteria: DeviceMembershipCriteria.devices([first.id])}
      :ok = PubSub.Changes.broadcast(account.id, :resources, %Change{lsn: 1, op: :update, old_struct: pool, struct: updated})

      pool_id = pool.id
      members = Bitmap.encode_devices([first])
      removed = Bitmap.encode_devices([second])
      nothing = Bitmap.encode_devices([])

      assert_receive {:device_pool_members_updated, ^pool_id, :all,
                      %{version: 2, previous: 1, members: ^members, added: ^nothing, removed: ^removed}}

      assert Cache.members(Cacheable.to_cache(updated), subject) == %{version: 2, members: members}
    end

    test "leaves the version alone when the new criteria hold the same devices", %{
      account: account,
      subject: subject
    } do
      member = client_fixture(account: account) |> fetch_device!()
      pool = device_pool_resource_fixture(account: account, devices: [member])
      :ok = Cache.subscribe(account.id)
      entry = Cache.members(Cacheable.to_cache(pool), subject)

      updated = %{
        pool
        | device_membership_criteria:
            DeviceMembershipCriteria.devices([member.id, Ecto.UUID.generate()])
      }

      :ok = PubSub.Changes.broadcast(account.id, :resources, %Change{lsn: 1, op: :update, old_struct: pool, struct: updated})
      :ok = PubSub.Changes.broadcast(account.id, :resources, %Change{lsn: 2, op: :update, old_struct: updated, struct: %{updated | name: "Renamed"}})

      refute_receive {:device_pool_members_updated, _, _, _}
      assert Cache.members(Cacheable.to_cache(updated), subject) == entry
      assert entry.version == 1
    end

    test "forgets a pool whose criteria change scope", %{account: account, actor: actor, subject: subject} do
      member = client_fixture(account: account, actor: actor) |> fetch_device!()
      pool = device_pool_resource_fixture(account: account, devices: [member])
      own = own_devices_pool_resource_fixture(account: account)
      :ok = Cache.subscribe(account.id)
      Cache.members(Cacheable.to_cache(pool), subject)
      Cache.members(Cacheable.to_cache(own), subject)

      updated = %{pool | device_membership_criteria: DeviceMembershipCriteria.own_devices()}
      :ok = PubSub.Changes.broadcast(account.id, :resources, %Change{lsn: 1, op: :update, old_struct: pool, struct: updated})

      grouped = %{own | device_membership_criteria: DeviceMembershipCriteria.actor_group(group_fixture(account: account).id)}
      :ok = PubSub.Changes.broadcast(account.id, :resources, %Change{lsn: 2, op: :update, old_struct: own, struct: grouped})

      assert_forgotten({account.id, pool.id, :all})
      assert_forgotten({account.id, own.id, {:actor, actor.id}})
      refute_receive {:device_pool_members_updated, _, _, _}
    end

    test "forgets a pool that is deleted or retyped", %{account: account, subject: subject} do
      member = client_fixture(account: account) |> fetch_device!()
      deleted = device_pool_resource_fixture(account: account, devices: [member])
      retyped = device_pool_resource_fixture(account: account, devices: [member])
      Cache.members(Cacheable.to_cache(deleted), subject)
      Cache.members(Cacheable.to_cache(retyped), subject)

      :ok = PubSub.Changes.broadcast(account.id, :resources, %Change{lsn: 1, op: :delete, old_struct: deleted})

      :ok =
        PubSub.Changes.broadcast(account.id, :resources, %Change{
          lsn: 2,
          op: :update,
          old_struct: retyped,
          struct: %{retyped | type: :dns, device_membership_criteria: nil}
        })

      assert_forgotten({account.id, deleted.id, :all})
      assert_forgotten({account.id, retyped.id, :all})
    end
  end

  # The change stream is dispatched asynchronously, so give the cache a moment to act.
  defp assert_forgotten(key, attempts \\ 50) do
    case :ets.lookup(:device_pool_bitmaps, key) do
      [] ->
        :ok

      _entry when attempts > 0 ->
        Process.sleep(10)
        assert_forgotten(key, attempts - 1)

      entry ->
        flunk("expected #{inspect(key)} to be forgotten, found #{inspect(entry)}")
    end
  end

  describe "for_subject?/2" do
    test "matches every subject for a listed pool and the actor for an own-devices pool", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      assert Cache.for_subject?(:all, subject)
      assert Cache.for_subject?({:actor, actor.id}, subject)
      refute Cache.for_subject?({:actor, actor_fixture(account: account).id}, subject)
    end
  end
end
