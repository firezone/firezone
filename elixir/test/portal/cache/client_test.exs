defmodule Portal.Cache.ClientTest do
  use Portal.DataCase, async: true

  alias Portal.Cache.Client, as: Cache
  alias Portal.Cache.Cacheable

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures

  describe "Portal.Cache.Cacheable.to_cache/1 for policy" do
    test "allows nil group_id for orphaned policies" do
      policy = %Portal.Policy{
        id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        group_id: nil,
        conditions: []
      }

      cached_policy = Cacheable.to_cache(policy)

      assert cached_policy.group_id == nil
      assert cached_policy.id == Ecto.UUID.dump!(policy.id)
      assert cached_policy.resource_id == Ecto.UUID.dump!(policy.resource_id)
    end
  end

  describe "update_resource/5" do
    setup do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)
      client = client_fixture(account: account, actor: actor)

      # Build session struct (mimics Socket.connect)
      version =
        case Portal.Version.fetch_version(subject.context.user_agent) do
          {:ok, version} -> version
          _ -> nil
        end

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        remote_ip_location_region: subject.context.remote_ip_location_region,
        version: version
      }

      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)

      site = site_fixture(account: account)

      resource =
        dns_resource_fixture(
          account: account,
          site: site
        )

      policy_fixture(account: account, group: group, resource: resource)

      %{
        account: account,
        subject: subject,
        client: client,
        session: session,
        site: site,
        resource: resource
      }
    end

    test "handles cached resource with nil site by fetching from database", %{
      subject: subject,
      client: client,
      session: session,
      site: site,
      resource: resource
    } do
      resource_id = Ecto.UUID.dump!(resource.id)
      site_id = Ecto.UUID.dump!(site.id)
      group_id = Ecto.UUID.dump!(resource.account_id)

      # Create a cache with a resource that has site: nil (simulating a failed hydration)
      cached_resource_with_nil_site = %Cacheable.Resource{
        id: resource_id,
        name: resource.name,
        type: resource.type,
        address: resource.address,
        address_description: resource.address_description,
        ip_stack: resource.ip_stack,
        filters: [],
        site: nil
      }

      cache = %Cache{
        policies: %{
          Ecto.UUID.dump!(Ecto.UUID.generate()) => %Cacheable.Policy{
            id: Ecto.UUID.dump!(Ecto.UUID.generate()),
            resource_id: resource_id,
            group_id: group_id,
            conditions: []
          }
        },
        resources: %{
          resource_id => cached_resource_with_nil_site
        },
        memberships: %{
          group_id => Ecto.UUID.dump!(Ecto.UUID.generate())
        },
        connectable_resources: []
      }

      # Simulate a resource update coming through WAL (site association not loaded)
      updated_resource = %{resource | name: "Updated Name"}

      # This should not crash - it should fetch the site from the database
      {:ok, _added, _removed, updated_cache} =
        Cache.update_resource(cache, updated_resource, client, session, subject)

      # Verify the site was hydrated from the database
      cached = Map.get(updated_cache.resources, resource_id)
      assert cached.site != nil
      assert cached.site.id == site_id
      assert cached.site.name == site.name
      assert cached.name == "Updated Name"
    end

    test "handles resource with nil site_id (site deleted)", %{
      subject: subject,
      client: client,
      session: session,
      resource: resource
    } do
      resource_id = Ecto.UUID.dump!(resource.id)
      site_id = Ecto.UUID.dump!(resource.site_id)
      group_id = Ecto.UUID.dump!(resource.account_id)

      cached_site = %Cacheable.Site{
        id: site_id,
        name: "Original Site"
      }

      cached_resource = %Cacheable.Resource{
        id: resource_id,
        name: resource.name,
        type: resource.type,
        address: resource.address,
        address_description: resource.address_description,
        ip_stack: resource.ip_stack,
        filters: [],
        site: cached_site
      }

      cache = %Cache{
        policies: %{
          Ecto.UUID.dump!(Ecto.UUID.generate()) => %Cacheable.Policy{
            id: Ecto.UUID.dump!(Ecto.UUID.generate()),
            resource_id: resource_id,
            group_id: group_id,
            conditions: []
          }
        },
        resources: %{
          resource_id => cached_resource
        },
        memberships: %{
          group_id => Ecto.UUID.dump!(Ecto.UUID.generate())
        },
        connectable_resources: [cached_resource]
      }

      # Simulate resource update where site was deleted (ON DELETE SET NULL)
      updated_resource = %{resource | site_id: nil, site: nil}

      # This should not crash - it should handle nil site_id gracefully
      {:ok, added, removed_ids, updated_cache} =
        Cache.update_resource(cache, updated_resource, client, session, subject)

      # Verify the resource now has nil site
      cached = Map.get(updated_cache.resources, resource_id)
      assert cached.site == nil

      # Resource should be removed from connectable_resources since it has no site
      assert added == []
      assert resource.id in removed_ids
    end

    test "reuses cached site when site_id has not changed", %{
      subject: subject,
      client: client,
      session: session,
      site: site,
      resource: resource
    } do
      resource_id = Ecto.UUID.dump!(resource.id)
      site_id = Ecto.UUID.dump!(site.id)
      group_id = Ecto.UUID.dump!(resource.account_id)

      cached_site = %Cacheable.Site{
        id: site_id,
        name: site.name
      }

      cached_resource = %Cacheable.Resource{
        id: resource_id,
        name: resource.name,
        type: resource.type,
        address: resource.address,
        address_description: resource.address_description,
        ip_stack: resource.ip_stack,
        filters: [],
        site: cached_site
      }

      cache = %Cache{
        policies: %{
          Ecto.UUID.dump!(Ecto.UUID.generate()) => %Cacheable.Policy{
            id: Ecto.UUID.dump!(Ecto.UUID.generate()),
            resource_id: resource_id,
            group_id: group_id,
            conditions: []
          }
        },
        resources: %{
          resource_id => cached_resource
        },
        memberships: %{
          group_id => Ecto.UUID.dump!(Ecto.UUID.generate())
        },
        connectable_resources: []
      }

      # Simulate a resource update (name change only, site unchanged)
      updated_resource = %{resource | name: "Updated Name"}

      {:ok, _added, _removed, updated_cache} =
        Cache.update_resource(cache, updated_resource, client, session, subject)

      # Verify the cached site was reused (same struct reference)
      cached = Map.get(updated_cache.resources, resource_id)
      assert cached.site == cached_site
      assert cached.name == "Updated Name"
    end
  end

  describe "authorize_device_access/3" do
    test "allows access when target client belongs to the given static device pool by ipv4" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)

      subject =
        subject_fixture(
          account: account,
          actor: actor,
          type: :client,
          user_agent: "Mac OS/14 apple-client/1.5.16"
        )

      client = client_fixture(account: account, actor: actor)
      target_actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: target_actor)
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)

      resource = static_device_pool_resource_fixture(account: account, clients: [target_client])
      policy_fixture(account: account, group: group, resource: resource)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        version: "1.5.16"
      }

      cache = Cache.recompute_connectable_resources(nil, client, session, subject) |> elem(3)

      target_ipv4 = target_client.ipv4.address
      target_id = target_client.id

      assert {:ok, ^target_id} =
               Cache.authorize_device_access(cache, resource.id, {:ipv4, target_ipv4})
    end

    test "allows access by ipv6" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)

      subject =
        subject_fixture(
          account: account,
          actor: actor,
          type: :client,
          user_agent: "Mac OS/14 apple-client/1.5.16"
        )

      client = client_fixture(account: account, actor: actor)
      target_actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: target_actor)
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)

      resource = static_device_pool_resource_fixture(account: account, clients: [target_client])
      policy_fixture(account: account, group: group, resource: resource)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        version: "1.5.16"
      }

      cache = Cache.recompute_connectable_resources(nil, client, session, subject) |> elem(3)

      target_ipv6 = target_client.ipv6.address
      target_id = target_client.id

      assert {:ok, ^target_id} =
               Cache.authorize_device_access(cache, resource.id, {:ipv6, target_ipv6})
    end

    test "rejects access when target client is not in the given pool" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)

      subject =
        subject_fixture(
          account: account,
          actor: actor,
          type: :client,
          user_agent: "Mac OS/14 apple-client/1.5.16"
        )

      client = client_fixture(account: account, actor: actor)
      target_actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: target_actor)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        version: "1.5.16"
      }

      cache = Cache.recompute_connectable_resources(nil, client, session, subject) |> elem(3)

      target_ipv4 = target_client.ipv4.address

      assert {:error, :forbidden} =
               Cache.authorize_device_access(cache, Ecto.UUID.generate(), {:ipv4, target_ipv4})
    end
  end

  describe "static_device_pool resource rendering" do
    test "populates addresses on connectable pool resources" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)

      subject =
        subject_fixture(
          account: account,
          actor: actor,
          type: :client,
          user_agent: "Mac OS/14 apple-client/1.5.16"
        )

      client = client_fixture(account: account, actor: actor)
      target_actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: target_actor)
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)

      resource = static_device_pool_resource_fixture(account: account, clients: [target_client])
      policy_fixture(account: account, group: group, resource: resource)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        version: "1.5.16"
      }

      {:ok, _added, _removed, cache} =
        Cache.recompute_connectable_resources(nil, client, session, subject)

      pool =
        Enum.find(cache.connectable_resources, &(&1.type == :static_device_pool))

      assert pool != nil

      target_id = target_client.id

      assert [
               %{
                 id: ^target_id,
                 ipv4: %Postgrex.INET{address: ipv4_address, netmask: 32},
                 ipv6: %Postgrex.INET{address: ipv6_address, netmask: 128}
               }
             ] = pool.devices

      assert ipv4_address == target_client.ipv4.address
      assert ipv6_address == target_client.ipv6.address
    end

    test "older clients do not see static_device_pool resources" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)

      subject =
        subject_fixture(
          account: account,
          actor: actor,
          type: :client,
          user_agent: "Mac OS/14 apple-client/1.5.0"
        )

      client = client_fixture(account: account, actor: actor)
      target_actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: target_actor)
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)

      resource = static_device_pool_resource_fixture(account: account, clients: [target_client])
      policy_fixture(account: account, group: group, resource: resource)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        version: "1.5.0"
      }

      {:ok, _added, _removed, cache} =
        Cache.recompute_connectable_resources(nil, client, session, subject)

      assert Enum.all?(cache.connectable_resources, &(&1.type != :static_device_pool))
      refute Map.has_key?(cache.pool_members, Ecto.UUID.dump!(resource.id))
    end
  end

  describe "track_authorized_device_ipv4/2" do
    test "appends the IPv4 to the cache's authorized set" do
      cache = %Cache{authorized_device_ipv4s: MapSet.new()}
      ipv4 = %Postgrex.INET{address: {10, 0, 0, 5}}

      cache = Cache.track_authorized_device_ipv4(cache, ipv4)

      assert MapSet.member?(cache.authorized_device_ipv4s, {10, 0, 0, 5})
    end
  end

  describe "add_policy/5 no-op paths" do
    setup do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)
      client = client_fixture(account: account, actor: actor)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        remote_ip_location_region: subject.context.remote_ip_location_region,
        version: "1.5.0"
      }

      %{account: account, actor: actor, subject: subject, client: client, session: session}
    end

    test "returns the cache unchanged when the policy's group isn't in memberships", %{
      account: account,
      subject: subject,
      client: client,
      session: session
    } do
      {:ok, _, _, cache} =
        Cache.recompute_connectable_resources(nil, client, session, subject)

      other_group = group_fixture(account: account)
      site = site_fixture(account: account)
      resource = dns_resource_fixture(account: account, site: site)
      policy = policy_fixture(account: account, group: other_group, resource: resource)

      assert {:ok, [], [], ^cache} =
               Cache.add_policy(cache, policy, client, session, subject)
    end
  end

  describe "update_policy/2 no-op when not in cache" do
    test "leaves the cache untouched if policy.id is unknown" do
      cache = %Cache{
        policies: %{},
        resources: %{},
        memberships: %{},
        connectable_resources: [],
        pool_members: %{},
        device_addresses: %{},
        authorized_device_ipv4s: MapSet.new()
      }

      policy = %Portal.Policy{
        id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        group_id: Ecto.UUID.generate(),
        conditions: []
      }

      assert {:ok, [], [], ^cache} = Cache.update_policy(cache, policy)
    end
  end

  describe "delete_policy/5 no-op when not in cache" do
    setup do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)
      client = client_fixture(account: account, actor: actor)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        remote_ip_location_region: subject.context.remote_ip_location_region,
        version: "1.5.0"
      }

      %{account: account, subject: subject, client: client, session: session}
    end

    test "returns cache unchanged for an unknown policy id", %{
      account: account,
      subject: subject,
      client: client,
      session: session
    } do
      {:ok, _, _, cache} =
        Cache.recompute_connectable_resources(nil, client, session, subject)

      group = group_fixture(account: account)
      site = site_fixture(account: account)
      resource = dns_resource_fixture(account: account, site: site)
      stranger_policy = policy_fixture(account: account, group: group, resource: resource)

      assert {:ok, [], [], ^cache} =
               Cache.delete_policy(cache, stranger_policy, client, session, subject)
    end
  end

  describe "update_resource/5 no-op when not in cache" do
    setup do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)
      client = client_fixture(account: account, actor: actor)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        remote_ip_location_region: subject.context.remote_ip_location_region,
        version: "1.5.0"
      }

      %{account: account, subject: subject, client: client, session: session}
    end

    test "returns cache unchanged when resource isn't in the cache", %{
      account: account,
      subject: subject,
      client: client,
      session: session
    } do
      {:ok, _, _, cache} =
        Cache.recompute_connectable_resources(nil, client, session, subject)

      site = site_fixture(account: account)
      stranger = dns_resource_fixture(account: account, site: site)

      assert {:ok, [], [], ^cache} =
               Cache.update_resource(cache, stranger, client, session, subject)
    end
  end

  describe "add_static_device_pool_member/3 no-op when not connectable" do
    setup do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)

      %{account: account, subject: subject}
    end

    test "ignores members for resources outside connectable_resources", %{
      account: account,
      subject: subject
    } do
      cache = %Cache{
        policies: %{},
        resources: %{},
        memberships: %{},
        connectable_resources: [],
        pool_members: %{},
        device_addresses: %{},
        authorized_device_ipv4s: MapSet.new()
      }

      target = client_fixture(account: account)

      member = %Portal.StaticDevicePoolMember{
        account_id: account.id,
        resource_id: Ecto.UUID.generate(),
        device_id: target.id
      }

      assert {:ok, [], [], ^cache} =
               Cache.add_static_device_pool_member(cache, member, subject)
    end
  end

  describe "handle_member_device_update/3" do
    test "no-op when device is not tracked" do
      cache = %Cache{
        policies: %{},
        resources: %{},
        memberships: %{},
        connectable_resources: [],
        pool_members: %{},
        device_addresses: %{},
        authorized_device_ipv4s: MapSet.new()
      }

      device = %Portal.Device{
        id: Ecto.UUID.generate(),
        type: :client,
        ipv4: %Postgrex.INET{address: {100, 64, 0, 5}, netmask: 32},
        ipv6: %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 1}, netmask: 128}
      }

      assert {:ok, [], [], ^cache} =
               Cache.handle_member_device_update(cache, device, nil)
    end

    test "no-op when addresses are unchanged" do
      did_bytes = Ecto.UUID.bingenerate()
      device_id = Ecto.UUID.load!(did_bytes)
      ipv4_tuple = {100, 64, 0, 5}
      ipv6_tuple = {0, 0, 0, 0, 0, 0, 0, 1}

      cache = %Cache{
        policies: %{},
        resources: %{},
        memberships: %{},
        connectable_resources: [],
        pool_members: %{},
        device_addresses: %{did_bytes => {ipv4_tuple, ipv6_tuple}},
        authorized_device_ipv4s: MapSet.new()
      }

      device = %Portal.Device{
        id: device_id,
        type: :client,
        ipv4: %Postgrex.INET{address: ipv4_tuple, netmask: 32},
        ipv6: %Postgrex.INET{address: ipv6_tuple, netmask: 128}
      }

      assert {:ok, [], [], ^cache} =
               Cache.handle_member_device_update(cache, device, nil)
    end
  end

  describe "delete_policy/5 keeps resource when another policy still references it" do
    test "keeps the resource and only removes the deleted policy" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)
      client = client_fixture(account: account, actor: actor)

      group_a = group_fixture(account: account)
      group_b = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group_a)
      membership_fixture(account: account, actor: actor, group: group_b)

      site = site_fixture(account: account)
      resource = dns_resource_fixture(account: account, site: site)

      policy_a = policy_fixture(account: account, group: group_a, resource: resource)
      policy_fixture(account: account, group: group_b, resource: resource)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        remote_ip_location_region: subject.context.remote_ip_location_region,
        version: "1.5.0"
      }

      {:ok, _, _, cache} =
        Cache.recompute_connectable_resources(nil, client, session, subject)

      assert {:ok, [], [], cache} =
               Cache.delete_policy(cache, policy_a, client, session, subject)

      assert Map.has_key?(cache.resources, Ecto.UUID.dump!(resource.id))
    end
  end

  describe "all_member_ips/2 empty input" do
    test "returns an empty list without hitting the DB" do
      assert Cache.Database.all_member_ips([], nil) == []
    end
  end

  describe "ensure_device_addresses fast path" do
    test "add_static_device_pool_member reuses existing device addresses without re-querying" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)

      target = client_fixture(account: account)
      did_bytes = Ecto.UUID.dump!(target.id)
      ipv4_tuple = target.ipv4.address
      ipv6_tuple = target.ipv6.address

      pool =
        static_device_pool_resource_fixture(account: account, clients: [])

      rid_bytes = Ecto.UUID.dump!(pool.id)

      cacheable_pool = Cacheable.to_cache(pool)

      cache = %Cache{
        policies: %{},
        resources: %{rid_bytes => cacheable_pool},
        memberships: %{},
        connectable_resources: [%{cacheable_pool | devices: []}],
        pool_members: %{},
        device_addresses: %{did_bytes => {ipv4_tuple, ipv6_tuple}},
        authorized_device_ipv4s: MapSet.new()
      }

      member = %Portal.StaticDevicePoolMember{
        account_id: account.id,
        resource_id: pool.id,
        device_id: target.id
      }

      assert {:ok, [_pool], [], updated} =
               Cache.add_static_device_pool_member(cache, member, subject)

      assert MapSet.member?(updated.pool_members[rid_bytes], did_bytes)
    end
  end

  describe "delete_static_device_pool_member/2" do
    test "keeps remaining members for a pool when only one is removed" do
      account = account_fixture()

      target_a = client_fixture(account: account)
      target_b = client_fixture(account: account)
      did_a = Ecto.UUID.dump!(target_a.id)
      did_b = Ecto.UUID.dump!(target_b.id)

      pool = static_device_pool_resource_fixture(account: account, clients: [])
      rid_bytes = Ecto.UUID.dump!(pool.id)

      cacheable_pool = Cacheable.to_cache(pool)

      cache = %Cache{
        policies: %{},
        resources: %{rid_bytes => cacheable_pool},
        memberships: %{},
        connectable_resources: [%{cacheable_pool | devices: []}],
        pool_members: %{rid_bytes => MapSet.new([did_a, did_b])},
        device_addresses: %{
          did_a => {target_a.ipv4.address, target_a.ipv6.address},
          did_b => {target_b.ipv4.address, target_b.ipv6.address}
        },
        authorized_device_ipv4s: MapSet.new()
      }

      member = %Portal.StaticDevicePoolMember{
        account_id: account.id,
        resource_id: pool.id,
        device_id: target_a.id
      }

      assert {:ok, _denied, [_pool], [], updated} =
               Cache.delete_static_device_pool_member(cache, member)

      assert MapSet.member?(updated.pool_members[rid_bytes], did_b)
      refute MapSet.member?(updated.pool_members[rid_bytes], did_a)
    end
  end

  describe "authorize_resource/5 logs when membership is missing from cache" do
    test "warns and returns :not_found when policy.group_id has no membership entry" do
      import ExUnit.CaptureLog

      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)
      client = client_fixture(account: account, actor: actor)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        remote_ip_location_region: subject.context.remote_ip_location_region,
        version: "1.5.0"
      }

      site = site_fixture(account: account)
      resource = dns_resource_fixture(account: account, site: site)
      resource_id = resource.id
      rid_bytes = Ecto.UUID.dump!(resource_id)
      orphan_group_id = Ecto.UUID.bingenerate()

      cacheable_resource = Cacheable.to_cache(resource)

      cache = %Cache{
        policies: %{
          Ecto.UUID.bingenerate() => %Portal.Cache.Cacheable.Policy{
            id: Ecto.UUID.bingenerate(),
            resource_id: rid_bytes,
            group_id: orphan_group_id,
            conditions: []
          }
        },
        resources: %{rid_bytes => cacheable_resource},
        memberships: %{},
        connectable_resources: [cacheable_resource],
        pool_members: %{},
        device_addresses: %{},
        authorized_device_ipv4s: MapSet.new()
      }

      log =
        capture_log(fn ->
          assert Cache.authorize_resource(cache, client, session, resource_id, subject) ==
                   {:error, :not_found}
        end)

      assert log =~ "membership not found in cache"
    end
  end

  describe "add_static_device_pool_member/3 add a second member" do
    test "extends existing pool_members entry instead of creating a new one" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)

      target_a = client_fixture(account: account)
      target_b = client_fixture(account: account)
      did_a = Ecto.UUID.dump!(target_a.id)
      did_b = Ecto.UUID.dump!(target_b.id)

      pool = static_device_pool_resource_fixture(account: account, clients: [])
      rid_bytes = Ecto.UUID.dump!(pool.id)

      cacheable_pool = Cacheable.to_cache(pool)

      cache = %Cache{
        policies: %{},
        resources: %{rid_bytes => cacheable_pool},
        memberships: %{},
        connectable_resources: [%{cacheable_pool | devices: []}],
        pool_members: %{rid_bytes => MapSet.new([did_a])},
        device_addresses: %{
          did_a => {target_a.ipv4.address, target_a.ipv6.address},
          did_b => {target_b.ipv4.address, target_b.ipv6.address}
        },
        authorized_device_ipv4s: MapSet.new()
      }

      member = %Portal.StaticDevicePoolMember{
        account_id: account.id,
        resource_id: pool.id,
        device_id: target_b.id
      }

      assert {:ok, [_pool], [], updated} =
               Cache.add_static_device_pool_member(cache, member, subject)

      members = updated.pool_members[rid_bytes]
      assert MapSet.member?(members, did_a)
      assert MapSet.member?(members, did_b)
    end
  end

  describe "all_memberships_for_actor_id!/2 includes Everyone group" do
    test "synthesises a membership entry when actor has access to Everyone" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)

      everyone_group =
        Portal.Repo.insert!(%Portal.Group{
          account_id: account.id,
          name: "Everyone",
          type: :managed,
          idp_id: nil
        })

      memberships = Cache.Database.all_memberships_for_actor_id!(actor.id, subject)

      assert Enum.any?(memberships, fn m ->
               m.group_id == everyone_group.id and is_nil(m.id)
             end)
    end
  end

  describe "fetch_resource_by_id/2 not_found path" do
    test "returns :not_found for an unknown resource id" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)

      assert Cache.Database.fetch_resource_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end
  end

  describe "render_pool_devices ignores orphan members without addresses" do
    test "skips members whose addresses aren't in device_addresses on refresh" do
      account = account_fixture()
      target_a = client_fixture(account: account)
      target_b = client_fixture(account: account)
      did_a = Ecto.UUID.dump!(target_a.id)
      did_b = Ecto.UUID.dump!(target_b.id)

      pool = static_device_pool_resource_fixture(account: account, clients: [])
      rid_bytes = Ecto.UUID.dump!(pool.id)

      cacheable_pool = Cacheable.to_cache(pool)

      cache = %Cache{
        policies: %{},
        resources: %{rid_bytes => cacheable_pool},
        memberships: %{},
        connectable_resources: [%{cacheable_pool | devices: []}],
        # Both did_a and did_b are members of the pool but only did_a has
        # device_addresses. When we remove did_a and refresh, render_pool_devices has
        # to skip did_b via the :error branch.
        pool_members: %{rid_bytes => MapSet.new([did_a, did_b])},
        device_addresses: %{did_a => {target_a.ipv4.address, target_a.ipv6.address}},
        authorized_device_ipv4s: MapSet.new()
      }

      member = %Portal.StaticDevicePoolMember{
        account_id: account.id,
        resource_id: pool.id,
        device_id: target_a.id
      }

      assert {:ok, _denied, [pool_view], [], updated} =
               Cache.delete_static_device_pool_member(cache, member)

      # did_b is still in pool_members but had no device_addresses, so the rendered
      # pool has no devices.
      assert pool_view.devices == []
      assert MapSet.member?(updated.pool_members[rid_bytes], did_b)
    end
  end

  describe "load_pool_state with multi-member pool" do
    test "tracks multiple device members in the same pool" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)

      subject =
        subject_fixture(
          account: account,
          actor: actor,
          type: :client,
          user_agent: "Mac OS/14 apple-client/1.5.16"
        )

      client = client_fixture(account: account, actor: actor)
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)

      target_a = client_fixture(account: account)
      target_b = client_fixture(account: account)

      pool =
        static_device_pool_resource_fixture(
          account: account,
          clients: [target_a, target_b]
        )

      policy_fixture(account: account, group: group, resource: pool)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: "Mac OS/14 apple-client/1.5.16",
        remote_ip: subject.context.remote_ip,
        version: "1.5.16"
      }

      {:ok, _, _, cache} =
        Cache.recompute_connectable_resources(nil, client, session, subject)

      rid_bytes = Ecto.UUID.dump!(pool.id)
      did_a = Ecto.UUID.dump!(target_a.id)
      did_b = Ecto.UUID.dump!(target_b.id)

      assert MapSet.member?(cache.pool_members[rid_bytes], did_a)
      assert MapSet.member?(cache.pool_members[rid_bytes], did_b)
    end
  end

  describe "ensure_device_addresses :error branch" do
    test "add_static_device_pool_member returns no-op when get_client_addresses can't find device" do
      import ExUnit.CaptureLog

      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)

      pool = static_device_pool_resource_fixture(account: account, clients: [])
      rid_bytes = Ecto.UUID.dump!(pool.id)

      cacheable_pool = Cacheable.to_cache(pool)

      cache = %Cache{
        policies: %{},
        resources: %{rid_bytes => cacheable_pool},
        memberships: %{},
        connectable_resources: [%{cacheable_pool | devices: []}],
        pool_members: %{},
        device_addresses: %{},
        authorized_device_ipv4s: MapSet.new()
      }

      member = %Portal.StaticDevicePoolMember{
        account_id: account.id,
        resource_id: pool.id,
        device_id: Ecto.UUID.generate()
      }

      log =
        capture_log(fn ->
          assert {:ok, [], [], ^cache} =
                   Cache.add_static_device_pool_member(cache, member, subject)
        end)

      assert log =~ "Addresses not found for client"
    end
  end

  describe "fetch_site_for_resource nil branch" do
    test "update_resource sets site to nil when get_site_by_id returns nil" do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)
      client = client_fixture(account: account, actor: actor)

      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)

      site = site_fixture(account: account)
      resource = dns_resource_fixture(account: account, site: site)
      policy_fixture(account: account, group: group, resource: resource)

      session = %Portal.ClientSession{
        device_id: client.id,
        account_id: client.account_id,
        user_agent: subject.context.user_agent,
        remote_ip: subject.context.remote_ip,
        remote_ip_location_region: subject.context.remote_ip_location_region,
        version: "1.5.0"
      }

      {:ok, _, _, cache} =
        Cache.recompute_connectable_resources(nil, client, session, subject)

      # Force the resource to point at a non-existent site, then run update_resource —
      # site will look "changed" relative to cache, but get_site_by_id returns nil.
      orphan_site_id = Ecto.UUID.generate()
      changed_resource = %{resource | site: nil, site_id: orphan_site_id}

      assert {:ok, _, _, updated} =
               Cache.update_resource(cache, changed_resource, client, session, subject)

      cached_resource = Map.fetch!(updated.resources, Ecto.UUID.dump!(resource.id))
      assert is_nil(cached_resource.site)
    end
  end
end
