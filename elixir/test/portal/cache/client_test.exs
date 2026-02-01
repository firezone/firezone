defmodule Portal.Cache.ClientTest do
  use Portal.DataCase, async: true

  alias Portal.Cache.Client, as: Cache
  alias Portal.Cache.Cacheable

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures

  describe "update_resource/4" do
    setup do
      account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)
      client = client_fixture(account: account, actor: actor)
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
        site: site,
        resource: resource
      }
    end

    test "handles cached resource with nil site by fetching from database", %{
      subject: subject,
      client: client,
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
        Cache.update_resource(cache, updated_resource, client, subject)

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
        Cache.update_resource(cache, updated_resource, client, subject)

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
        Cache.update_resource(cache, updated_resource, client, subject)

      # Verify the cached site was reused (same struct reference)
      cached = Map.get(updated_cache.resources, resource_id)
      assert cached.site == cached_site
      assert cached.name == "Updated Name"
    end
  end
end
