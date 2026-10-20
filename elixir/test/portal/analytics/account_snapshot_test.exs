defmodule Portal.Analytics.AccountSnapshotTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.LogSinkFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  alias Portal.Analytics.AccountSnapshot

  @now ~U[2026-10-16 12:00:00.000000Z]

  describe "Database.fetch_counts_for_accounts/2" do
    test "returns no counts for an account without records" do
      account = account_fixture()

      assert AccountSnapshot.Database.fetch_counts_for_accounts([account], @now) == %{}
    end

    test "counts records per account" do
      account = account_fixture()
      other_account = account_fixture()
      site = site_fixture(account: account)

      admin_actor_fixture(account: account)
      actor = actor_fixture(account: account, type: :account_user)
      disabled_actor_fixture(account: account)
      service_account_fixture(account: account)

      cidr_resource = cidr_resource_fixture(account: account, site: site)
      dns_resource = dns_resource_fixture(account: account, site: site)
      ip_resource = ip_resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      managed_group_fixture(account: account)

      policy_fixture(account: account, group: group, resource: cidr_resource)
      disabled_policy_fixture(%{account: account, group: group, resource: dns_resource})
      policy_with_conditions_fixture(%{account: account, group: group, resource: ip_resource})

      active_client = verified_client_fixture(%{account: account, actor: actor})
      stale_client = client_fixture(account: account, actor: actor)
      put_last_seen(active_client, DateTime.add(@now, -1, :hour))
      put_last_seen(stale_client, DateTime.add(@now, -10, :day))

      gateway_fixture(
        account: account,
        site: site,
        last_seen_at: DateTime.add(@now, -1, :hour),
        last_seen_version: "1.4.0"
      )

      gateway_fixture(
        account: account,
        site: site,
        last_seen_at: DateTime.add(@now, -40, :day),
        last_seen_version: "1.0.0"
      )

      email_otp_provider_fixture(account: account)
      datadog_log_sink_fixture(account: account)

      resource_fixture(account: other_account)

      counts = AccountSnapshot.Database.fetch_counts_for_accounts([account], @now)

      assert Map.keys(counts) == [account.id]

      assert %{
               admins: 1,
               users: 1,
               service_accounts: 1,
               api_clients: 0,
               resources_cidr: 1,
               resources_dns: 1,
               resources_ip: 1,
               policies: 3,
               policies_disabled: 1,
               policies_with_conditions: 1,
               policies_with_postures: 0,
               groups_managed: 1,
               clients: 2,
               clients_active_1d: 1,
               clients_active_7d: 1,
               clients_active_30d: 2,
               clients_verified: 1,
               gateways: 2,
               gateways_active_1d: 1,
               gateway_versions: ["1.4.0"],
               auth_provider_types: ["email_otp"],
               log_sink_types: ["datadog"]
             } = counts[account.id]
    end
  end

  describe "stream/1" do
    test "counts devices connected since before a window as active in it" do
      account = account_fixture()
      site = site_fixture(account: account)
      actor = actor_fixture(account: account)
      connected_at = DateTime.utc_now()

      gateway = gateway_fixture(account: account, site: site, last_seen_at: connected_at)
      client = client_fixture(account: account, actor: actor)
      put_last_seen(client, connected_at)
      offline_client = client_fixture(account: account, actor: actor)
      put_last_seen(offline_client, connected_at)

      :ok = Portal.Presence.Devices.connect(gateway, Ecto.UUID.generate())
      :ok = Portal.Presence.Devices.connect(client, Ecto.UUID.generate())

      # 45 days later, the gateway and client have stayed connected the whole time.
      group_set = group_set_for(account, DateTime.add(connected_at, 45, :day))

      assert group_set["gateways_count"] == 1
      assert group_set["gateways_online_count"] == 1
      assert group_set["gateways_active_1d_count"] == 1
      assert group_set["clients_count"] == 2
      assert group_set["clients_online_count"] == 1
      assert group_set["clients_active_1d_count"] == 1
      assert group_set["clients_active_7d_count"] == 1
      assert group_set["clients_active_30d_count"] == 1
    end

    test "counts a device that connected inside a window once" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      connected_at = DateTime.utc_now()

      client = client_fixture(account: account, actor: actor)
      put_last_seen(client, connected_at)
      :ok = Portal.Presence.Devices.connect(client, Ecto.UUID.generate())

      group_set = group_set_for(account, DateTime.add(connected_at, 1, :hour))

      assert group_set["clients_online_count"] == 1
      assert group_set["clients_active_1d_count"] == 1
      assert group_set["clients_active_7d_count"] == 1
      assert group_set["clients_active_30d_count"] == 1
    end

    test "skips disabled accounts" do
      account = account_fixture()
      disabled_account = disabled_account_fixture()

      group_keys =
        @now
        |> AccountSnapshot.stream()
        |> Enum.to_list()
        |> List.flatten()
        |> Enum.flat_map(fn
          %{"event" => "$groupidentify", "properties" => %{"$group_key" => key}} -> [key]
          _event -> []
        end)

      assert account.id in group_keys
      refute disabled_account.id in group_keys
    end
  end

  describe "build_events/3" do
    test "builds a group identify and a snapshot event per account" do
      account = team_account_fixture()
      account_id = account.id

      counts = %{account.id => %{resources: 2, resources_dns: 2, auth_provider_types: ["google"]}}

      assert [
               %{"event" => "$groupidentify", "properties" => identify},
               %{"event" => "Account Snapshot", "properties" => snapshot}
             ] = AccountSnapshot.build_events([account], counts, @now)

      assert %{
               "distinct_id" => ^account_id,
               "$group_type" => "account",
               "$group_key" => ^account_id,
               "$process_person_profile" => false,
               "$group_set" => group_set
             } = identify

      assert group_set["plan_type"] == "team"
      assert group_set["subscription_status"] == nil
      assert group_set["trial_ends_at"] == nil
      assert group_set["add_ons"] == []
      assert group_set["resources_count"] == 2
      assert group_set["resources_dns_count"] == 2
      assert group_set["resources_cidr_count"] == 0
      assert group_set["auth_provider_types"] == ["google"]
      assert group_set["log_sink_types"] == []

      assert snapshot["$groups"] == %{"account" => account_id}
      assert snapshot["distinct_id"] == account_id
      assert Map.take(snapshot, Map.keys(group_set)) == group_set
    end

    test "includes the Stripe subscription details" do
      account =
        account_fixture(
          metadata: %{
            stripe: %{
              product_name: "Business",
              subscription_status: "trialing",
              trial_ends_at: ~U[2026-11-01 00:00:00.000000Z],
              support_type: "email",
              add_ons: [%{name: "Seats", quantity: 5}, %{name: "Device posture", quantity: 1}]
            }
          }
        )

      [%{"properties" => %{"$group_set" => group_set}}, _snapshot] =
        AccountSnapshot.build_events([account], %{}, @now)

      assert %{
               "plan_type" => "business",
               "subscription_status" => "trialing",
               "trial_ends_at" => "2026-11-01T00:00:00.000000Z",
               "support_type" => "email",
               "add_ons" => ["Device posture", "Seats"]
             } = group_set
    end

    test "uses the same event UUIDs for a retry on the same day" do
      account = account_fixture()

      [identify, snapshot] = AccountSnapshot.build_events([account], %{}, @now)

      [retry_identify, retry_snapshot] =
        AccountSnapshot.build_events([account], %{}, DateTime.add(@now, 1, :hour))

      [next_identify, next_snapshot] =
        AccountSnapshot.build_events([account], %{}, DateTime.add(@now, 1, :day))

      assert {:ok, _uuid} = Ecto.UUID.cast(identify["uuid"])
      assert identify["uuid"] != snapshot["uuid"]
      assert retry_identify["uuid"] == identify["uuid"]
      assert retry_snapshot["uuid"] == snapshot["uuid"]
      assert next_identify["uuid"] != identify["uuid"]
      assert next_snapshot["uuid"] != snapshot["uuid"]
    end

    test "does not include customer-entered data" do
      account = account_fixture(name: "Secret Account Name")
      actor = actor_fixture(account: account, email: "secret@example.com", name: "Secret Person")
      site = site_fixture(account: account, name: "Secret Site")

      resource =
        dns_resource_fixture(
          account: account,
          site: site,
          name: "Secret Resource",
          address: "secret.example.com"
        )

      gateway_fixture(account: account, site: site, last_seen_remote_ip: {203, 0, 113, 7})
      client_fixture(account: account, actor: actor, name: "Secret Laptop")

      counts = AccountSnapshot.Database.fetch_counts_for_accounts([account], @now)
      payload = JSON.encode!(AccountSnapshot.build_events([account], counts, @now))

      for value <- [
            account.name,
            account.slug,
            actor.email,
            actor.name,
            site.name,
            resource.name,
            resource.address,
            "Secret Laptop",
            "203.0.113.7"
          ] do
        refute payload =~ value
      end
    end
  end

  defp group_set_for(account, now) do
    now
    |> AccountSnapshot.stream()
    |> Enum.to_list()
    |> List.flatten()
    |> Enum.find_value(fn
      %{"event" => "$groupidentify", "properties" => %{"$group_key" => key, "$group_set" => set}}
      when key == account.id ->
        set

      _event ->
        nil
    end)
  end

  defp put_last_seen(device, last_seen_at) do
    device
    |> Ecto.Changeset.change(last_seen_at: last_seen_at)
    |> Repo.update!()
  end
end
