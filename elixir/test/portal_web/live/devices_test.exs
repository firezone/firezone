defmodule PortalWeb.DevicesTest do
  use PortalWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live: 2]

  # The table loads in an async task, so wait for it before returning.
  defp live(conn, path) do
    case Phoenix.LiveViewTest.live(conn, path) do
      {:ok, lv, _html} -> {:ok, lv, render_async(lv)}
      other -> other
    end
  end

  import Ecto.Query, only: [from: 2]
  alias Portal.{Device, Repo}
  alias Portal.Changes.Change

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DefenderFixtures
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures
  import Portal.IruFixtures
  import Portal.SantaFixtures
  import Portal.SentinelOneFixtures
  import Portal.SophosFixtures
  import Portal.DeviceFixtures
  import Portal.ClientSessionFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/devices"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "index (default action)" do
    test "loads the table only after the socket connects", %{conn: conn, account: account, actor: actor} do
      client_fixture(account: account, actor: actor)

      conn = authorize_conn(conn, actor)

      static = conn |> get(~p"/#{account}/devices") |> html_response(200) |> Floki.parse_document!()
      assert [_] = Floki.find(static, "#devices-skeleton")
      assert Floki.find(static, "#devices-rows tr") == []

      {:ok, lv, _html} = live(conn, ~p"/#{account}/devices")
      assert has_element?(lv, "#devices-rows tr")
      refute has_element?(lv, "#devices-skeleton")
    end

    test "renders empty state when no devices exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert html =~ "Devices"
      assert html =~ "No devices yet"
    end

    test "renders client list page", %{conn: conn, account: account, actor: actor} do
      client = client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert html =~ "Devices"
      assert html =~ client.slug
    end

    test "lists a client whose users were all deleted", %{conn: conn, account: account, actor: actor} do
      former = actor_fixture(account: account)
      client = client_fixture(account: account, actor: former)
      Repo.delete!(former)
      conn = authorize_conn(conn, actor)

      {:ok, _lv, html} = live(conn, ~p"/#{account}/devices")

      assert html =~ client.slug
      assert html =~ "No user"

      {:ok, _lv, html} = live(conn, ~p"/#{account}/devices/#{client.id}")

      assert html =~ client.name
      refute html =~ "Owner</"
    end

    test "filters devices by client name, slug, or actor name/email", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      owner = actor_fixture(account: account, name: "Owner Person", email: "owner@example.com")
      client = client_fixture(account: account, actor: owner, name: "Owner Laptop")
      other_client = client_fixture(account: account, actor: actor, name: "Other Laptop")

      conn = authorize_conn(conn, actor)

      for search <- [client.name, client.slug, owner.name, owner.email] do
        {:ok, lv, _html} =
          live(conn, ~p"/#{account}/devices?#{%{"devices_filter[search]" => search}}")

        assert has_element?(lv, "#device-#{client.id}")
        refute has_element?(lv, "#device-#{other_client.id}")
      end
    end

    test "finds a device by any of its users", %{conn: conn, account: account, actor: actor} do
      later = actor_fixture(account: account, name: "Later Person", email: "later@example.com")
      client = client_fixture(account: account, name: "Shared Laptop")
      other_client = client_fixture(account: account, actor: actor, name: "Other Laptop")
      now = DateTime.utc_now()

      Repo.insert!(%Portal.DeviceActor{
        account_id: account.id,
        device_id: client.id,
        actor_id: later.id,
        first_seen_at: now,
        last_seen_at: now
      })

      conn = authorize_conn(conn, actor)

      for search <- [later.name, later.email] do
        {:ok, lv, _html} = live(conn, ~p"/#{account}/devices?#{%{"devices_filter[search]" => search}}")

        assert has_element?(lv, "#device-#{client.id}")
        refute has_element?(lv, "#device-#{other_client.id}")
      end
    end

    test "offers the trust levels to filter by", %{conn: conn, account: account, actor: actor} do
      client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert html =~ "All trust levels"
      refute html =~ "All Trust levels"
    end

    test "filters by attestation level", %{conn: conn, account: account, actor: actor} do
      verified_actor = actor_fixture(account: account, name: "Verified Owner")

      verified = verified_client_fixture(%{account: account, actor: verified_actor, name: "Work Mac"})

      attested =
        client_fixture(
          account: account,
          actor: actor,
          name: "Attested Mac",
          last_attested_at: DateTime.utc_now()
        )

      plain = client_fixture(account: account, actor: actor, name: "Lab Box")
      conn = authorize_conn(conn, actor)

      for {level, shown, hidden} <- [
            {"verified", verified, [attested, plain]},
            {"attested", attested, [verified, plain]},
            {"none", plain, [verified, attested]}
          ] do
        {:ok, lv, _html} =
          live(conn, ~p"/#{account}/devices?#{%{"devices_filter[attestation]" => level}}")

        assert has_element?(lv, "#device-#{shown.id}")

        for client <- hidden do
          refute has_element?(lv, "#device-#{client.id}")
        end
      end
    end

    test "a device that attested cannot be verified by hand", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client =
        client_fixture(
          account: account,
          actor: actor,
          name: "Attested Mac",
          last_attested_at: DateTime.utc_now()
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert has_element?(lv, "button[disabled]", "Verify")
      refute has_element?(lv, "button[phx-click='verify_device']")
      assert render(lv) =~ "This device is already attested through an X.509 certificate."
      assert render(lv) =~ "This device is attested through an X.509 certificate."
    end

    test "orders by slug and opens the panel from row click", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      alpha = client_fixture(account: account, actor: actor, slug: "alpha-client")
      omega = client_fixture(account: account, actor: actor, slug: "omega-client")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      element(
        lv,
        "button[phx-click='order_by'][phx-value-table_id='devices'][phx-value-order_by='devices:asc:slug']"
      )
      |> render_click()

      html = render_async(lv)

      assert html =~ alpha.slug
      assert html =~ omega.slug
      assert elem(:binary.match(html, omega.slug), 0) < elem(:binary.match(html, alpha.slug), 0)

      render_click(element(lv, "#device-#{omega.id}"))

      assert_patch(
        lv,
        ~p"/#{account}/devices/#{omega.id}?#{%{devices_order_by: "devices:desc:slug"}}"
      )

      assert has_element?(lv, "h2", omega.slug)
    end
  end

  describe "status badge" do
    test "shows the device trust shield on an online attested device", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      attested =
        client_fixture(account: account, actor: actor, last_attested_at: DateTime.utc_now())

      plain = client_fixture(account: account, actor: actor)

      offline =
        client_fixture(account: account, actor: actor, last_attested_at: DateTime.utc_now())

      :ok = Portal.Presence.Devices.Account.track(attested)
      :ok = Portal.Presence.Devices.Account.track(plain)

      conn = authorize_conn(conn, actor)
      {:ok, lv, _html} = live(conn, ~p"/#{account}/devices")

      assert has_element?(lv, "#device-#{attested.id} [title='Attested'].ri-shield-keyhole-line")
      refute has_element?(lv, "#device-#{plain.id} [title='Attested']")
      refute has_element?(lv, "#device-#{offline.id} [title='Attested']")

      {:ok, lv, _html} = live(conn, ~p"/#{account}/devices/#{attested.id}")

      assert has_element?(lv, "#device-panel [title='Attested'].ri-shield-keyhole-line")
    end
  end

  describe ":show action" do
    test "cautions that the device reports its own fields", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor, device_serial: "SN-SPOOFABLE")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Reported by Client"
      assert html =~ "The Firezone Client reads and reports these values."
      assert html =~ "X.509 Device Trust"
      assert html =~ ~p"/#{account}/settings/trust_anchors"
    end

    test "drops the device trust call to action once the device has attested", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client =
        client_fixture(
          account: account,
          actor: actor,
          device_serial: "SN-ATTESTED",
          last_attested_at: DateTime.utc_now()
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Reported by Client"
      refute html =~ "to strongly identify this device"
    end

    test "renders client detail panel with device and network details", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      owner = actor_fixture(account: account, name: "Panel Owner")

      client =
        verified_client_fixture(%{
          account: account,
          actor: owner,
          name: "Engineer Laptop",
          device_serial: "SN-123",
          device_uuid: "UUID-123",
          identifier_for_vendor: "IFV-123"
        })

      session =
        client_session_fixture(
          account: account,
          actor: owner,
          client: client,
          user_agent: "macOS/15.0 apple-client/1.4.0",
          remote_ip: {203, 0, 113, 10},
          remote_ip_location_region: "US",
          remote_ip_location_city: "San Francisco",
          remote_ip_location_lat: 37.7749,
          remote_ip_location_lon: -122.4194,
          version: "1.4.0"
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ client.name
      assert html =~ owner.name
      assert html =~ "SN-123"
      assert html =~ "UUID-123"
      assert html =~ "IFV-123"
      assert html =~ "Remote IP"
      assert html =~ "203.0.113.10"
      assert html =~ "San Francisco"
      assert html =~ "United States of America"
      assert html =~ "https://www.google.com/maps/place/37.7749,-122.4194"
      assert html =~ "Open remote IP location in Google Maps"
      assert html =~ "Tunnel IPv4"
      assert html =~ "Tunnel IPv6"
      assert html =~ "Trust level"
      assert html =~ "An admin vouched for the values this Device reports."
      assert html =~ "Verified"
      assert html =~ session.last_seen_version

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/devices")
    end

    test "lists the device pools the client belongs to", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      pool =
        device_pool_resource_fixture(
          account: account,
          name: "Engineering Laptops",
          devices: [client]
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Device Pools"
      assert html =~ pool.name
      assert html =~ ~p"/#{account}/resources/#{pool.id}"
    end

    test "omits the device pools section when the client is in no pools", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      refute html =~ "Device Pools"
    end

    test "ignores a tab switch queued while the client panel is closing", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/devices")

      render_click(lv, "switch_device_tab", %{"tab" => "authorizations"})

      refute has_element?(lv, "#device-panel > div")
    end

    test "marks only older client versions as outdated" do
      older_html =
        render_component(&PortalWeb.Devices.Components.version/1,
          current: "0.9.0",
          latest: "1.0.0"
        )

      assert older_html =~ "A newer version"
      assert older_html =~ "1.0.0"

      latest_html =
        render_component(&PortalWeb.Devices.Components.version/1,
          current: "1.0.0",
          latest: "1.0.0"
        )

      assert latest_html =~ "This component is up to date."
      refute latest_html =~ "A newer version"

      newer_html =
        render_component(&PortalWeb.Devices.Components.version/1,
          current: "1.0.1",
          latest: "1.0.0"
        )

      assert newer_html =~ "This component is up to date."
      refute newer_html =~ "A newer version"
    end

    test "shows delete confirmation, cancels it, then deletes client", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      html = render_click(lv, "confirm_delete_device")
      assert html =~ "Delete this device?"

      html = render_click(lv, "cancel_delete_device")
      refute html =~ "Delete this device?"

      render_click(lv, "confirm_delete_device")
      render_click(lv, "delete_device")

      assert_patch(lv, ~p"/#{account}/devices")
      assert is_nil(Repo.get_by(Device, account_id: account.id, id: client.id))
    end

    test "verifies an unverified client", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor, name: "Unverified Laptop")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert has_element?(lv, "button[phx-click='verify_device']", "Verify")

      html = render_click(lv, "verify_device")
      updated_client = Repo.get_by!(Device, account_id: account.id, id: client.id)

      assert html =~ "Device &quot;#{client.name}&quot; was verified."
      assert html =~ "Verified"
      assert updated_client.verified_at
      refute has_element?(lv, "button[phx-click='verify_device']", "Verify")
      assert has_element?(
               lv,
               "button[phx-click='confirm_unverify_device']",
               "Revoke verification"
             )
    end

    test "shows unverify confirmation and cancels", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = verified_client_fixture(%{account: account, actor: actor, name: "Verified Laptop"})

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      html = render_click(lv, "confirm_unverify_device")
      assert html =~ "Revoke verification for this device?"
      assert html =~ "Current authorizations for this device may be revoked."

      html = render_click(lv, "cancel_unverify_device")
      updated_client = Repo.get_by!(Device, account_id: account.id, id: client.id)

      refute html =~ "Revoke verification for this device?"
      assert updated_client.verified_at
      assert has_element?(
               lv,
               "button[phx-click='confirm_unverify_device']",
               "Revoke verification"
             )

      refute has_element?(lv, "button[phx-click='verify_device']", "Verify")
    end

    test "shows unverify confirmation and accepts", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = verified_client_fixture(%{account: account, actor: actor, name: "Verified Laptop"})

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      render_click(lv, "confirm_unverify_device")
      html = render_click(lv, "unverify_device")
      updated_client = Repo.get_by!(Device, account_id: account.id, id: client.id)

      assert html =~ "Device &quot;#{client.name}&quot; was unverified."
      refute html =~ "Revoke verification for this device?"
      assert is_nil(updated_client.verified_at)
      assert has_element?(lv, "button[phx-click='verify_device']", "Verify")
      refute has_element?(
               lv,
               "button[phx-click='confirm_unverify_device']",
               "Revoke verification"
             )
    end

    test "patches to devices index with flash when device does not exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      missing_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/devices/#{missing_id}")

      assert to == ~p"/#{account}/devices"
      assert flash["error"] =~ "Device does not exist"
    end
  end

  describe ":edit action" do
    test "renders edit form pre-populated with client name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}/edit")

      assert html =~ "Edit Device"
      assert html =~ "Save"
      assert html =~ client.name
    end

    test "offers a copy button for the device id and the slug", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor, name: "Old Client Name")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      for field <- ["device-id", "device-slug", "device-ipv4", "device-ipv6"] do
        id = "#{field}-#{client.id}"

        assert has_element?(lv, "##{id}[phx-hook='CopyClipboard']")
        assert has_element?(lv, "button[data-copy-to-clipboard-target='#{id}-code']")
      end

      assert has_element?(lv, "#device-id-#{client.id}-code", client.id)
      assert has_element?(lv, "#device-slug-#{client.id}-code", Portal.Device.fqdn(client))
      assert has_element?(lv, "#device-ipv4-#{client.id}-code", to_string(client.ipv4))
      assert has_element?(lv, "#device-ipv6-#{client.id}-code", to_string(client.ipv6))
    end

    test "shows the slug and lets an admin change it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor, name: "Old Client Name")

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Tunnel DNS Name"
      assert html =~ "old-client-name.firezone.network"

      html = render_click(lv, "open_device_edit_form")

      assert html =~ "Slug"
      assert html =~ "Used to reach this device directly through a"
      assert html =~ ">device pool</a>. Must be unique in the account."
      refute has_element?(lv, "input[name='device[slug]'].font-mono")
      assert has_element?(lv, "input[name='device[slug]'][required]")

      for bad <- ["Bad Slug", "-laptop", "laptop-", "my.laptop", "my_laptop", String.duplicate("a", 64)] do
        html =
          lv
          |> form("[phx-submit='submit_device_edit_form']", device: %{slug: bad})
          |> render_change()

        assert html =~ "must be 1 to 63 lowercase letters, digits or hyphens"
      end

      html =
        lv
        |> form("[phx-submit='submit_device_edit_form']", device: %{slug: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"

      html =
        lv
        |> form("[phx-submit='submit_device_edit_form']", device: %{slug: "laptop"})
        |> render_submit()

      assert html =~ "Device updated successfully."
      assert html =~ "laptop.firezone.network"
    end

    test "refuses a slug another device in the account already holds", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      taken = client_fixture(account: account, actor: actor, name: "Taken")
      client = client_fixture(account: account, actor: actor, name: "Mine")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      render_click(lv, "open_device_edit_form")

      html =
        lv
        |> form("[phx-submit='submit_device_edit_form']", device: %{slug: taken.slug})
        |> render_submit()

      assert html =~ "is already used by another device in this account"
      assert Repo.get_by!(Device, id: client.id).slug == client.slug
    end

    test "opens edit form from show panel, validates, cancels, and updates client", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor, name: "Old Client Name")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      render_click(lv, "open_device_edit_form")
      assert_patch(lv, ~p"/#{account}/devices/#{client.id}/edit")

      html =
        lv
        |> form("[phx-submit='submit_device_edit_form']", device: %{name: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"

      render_click(lv, "cancel_device_edit_form")
      assert_patch(lv, ~p"/#{account}/devices/#{client.id}")

      render_click(lv, "open_device_edit_form")

      html =
        lv
        |> form("[phx-submit='submit_device_edit_form']", device: %{name: "Updated Client Name"})
        |> render_submit()

      updated_client = Repo.get_by!(Device, account_id: account.id, id: client.id)

      assert html =~ "Device updated successfully."
      assert html =~ "Updated Client Name"
      assert updated_client.name == "Updated Client Name"
      assert_patch(lv, ~p"/#{account}/devices/#{client.id}")
    end
  end

  describe ":show action async details" do
    test "renders the header before the device pools load", %{conn: conn, account: account, actor: actor} do
      client = client_fixture(account: account, actor: actor, name: "Async Laptop")
      device_pool_resource_fixture(account: account, name: "Async Pool", devices: [client])

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> Phoenix.LiveViewTest.live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Async Laptop"
      assert html =~ "device-pools-loading"
      refute html =~ "Async Pool"

      html = render_async(lv)
      assert html =~ "Async Pool"
      refute html =~ "device-pools-loading"
    end

    test "never shows the previous device's pools on the next one", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      first = client_fixture(account: account, actor: actor)
      second = client_fixture(account: account, actor: actor)
      device_pool_resource_fixture(account: account, name: "First Pool", devices: [first])
      device_pool_resource_fixture(account: account, name: "Second Pool", devices: [second])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> Phoenix.LiveViewTest.live(~p"/#{account}/devices/#{first.id}")

      html = render_patch(lv, ~p"/#{account}/devices/#{second.id}")
      refute html =~ "First Pool"

      html = render_async(lv)
      assert html =~ "Second Pool"
      refute html =~ "First Pool"
    end

    test "loads authorizations only for the device they belong to", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      first = client_fixture(account: account, actor: actor)
      second = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site, name: "Auth Target")
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)
      policy = policy_fixture(account: account, group: group, resource: resource)

      policy_authorization_fixture(
        account: account,
        actor: actor,
        client: first,
        gateway: gateway,
        resource: resource,
        group: group,
        policy: policy,
        token: token
      )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> Phoenix.LiveViewTest.live(~p"/#{account}/devices/#{first.id}?tab=authorizations")

      render_patch(lv, ~p"/#{account}/devices/#{second.id}")
      html = render_patch(lv, ~p"/#{account}/devices/#{second.id}?tab=authorizations")
      refute html =~ "Auth Target"

      html = render_async(lv)
      assert html =~ "No recent authorizations"
      refute html =~ "Auth Target"
    end

    test "keeps loaded pools when switching tabs", %{conn: conn, account: account, actor: actor} do
      client = client_fixture(account: account, actor: actor)
      device_pool_resource_fixture(account: account, name: "Kept Pool", devices: [client])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      render_click(lv, "switch_device_tab", %{"tab" => "authorizations"})
      render_async(lv)
      render_click(lv, "switch_device_tab", %{"tab" => "overview"})

      html = render(lv)
      assert html =~ "Kept Pool"
      refute html =~ "device-pools-loading"
    end
  end

  describe ":show action authorizations tab" do
    test "tab bar shows Overview and Authorizations tabs", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Overview"
      assert html =~ "Authorizations"
    end

    test "switching to Authorizations tab patches URL", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      lv
      |> element("button[phx-click='switch_device_tab'][phx-value-tab='authorizations']")
      |> render_click()

      assert_patch(lv, ~p"/#{account}/devices/#{client.id}?tab=authorizations")
    end

    test "switching back to Overview tab patches URL", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=authorizations")

      lv
      |> element("button[phx-click='switch_device_tab'][phx-value-tab='overview']")
      |> render_click()

      assert_patch(lv, ~p"/#{account}/devices/#{client.id}?tab=overview")
    end

    test "Authorizations tab shows empty state when no authorizations exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=authorizations")

      assert html =~ "No recent authorizations"

      assert has_element?(
               lv,
               "[data-authorization-flow-logs-notice] a[href='#{~p"/#{account}/logs/flow_logs"}']",
               "flow logs"
             )
    end

    test "Authorizations tab renders resource and group name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      _membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)
      policy = policy_fixture(account: account, group: group, resource: resource)

      _authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          gateway: gateway,
          resource: resource,
          group: group,
          policy: policy,
          token: token
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=authorizations")

      assert html =~ resource.name
      assert html =~ group.name
    end

    test "Overview tab still renders correctly as default (regression)", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client =
        verified_client_fixture(%{
          account: account,
          actor: actor,
          name: "Regression Laptop"
        })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Regression Laptop"
      assert html =~ "Tunnel IPv4"
      assert html =~ "Tunnel IPv6"
    end
  end

  describe "count badge" do
    test "shows total client count after async load", %{conn: conn, account: account, actor: actor} do
      _client = client_fixture(account: account, actor: actor)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> Phoenix.LiveViewTest.live(~p"/#{account}/devices")

      assert html =~ "Loading..."

      html = render_async(lv)

      assert has_element?(lv, "#devices-count", "1")
      refute html =~ "Loading..."
    end

    test "increments count on client insert change", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      render_async(lv)

      send(lv.pid, %Change{op: :insert, struct: %Device{type: :client}})

      assert has_element?(lv, "#devices-count", "1")
    end

    test "decrements count on client delete change", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _client = client_fixture(account: account, actor: actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      render_async(lv)

      send(lv.pid, %Change{op: :delete, old_struct: %Device{type: :client}})

      assert has_element?(lv, "#devices-count", "0")
    end

    test "marks the table stale on client update change", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      render_async(lv)
      refute has_element?(lv, "#devices-reload-btn")

      {:ok, _updated} =
        client
        |> Ecto.Changeset.change(slug: "renamed-client")
        |> Repo.update()

      send(lv.pid, %Change{op: :update, struct: %Device{type: :client, id: client.id}})

      assert has_element?(lv, "#devices-reload-btn")

      render_click(lv, "reload", %{"table_id" => "devices"})
      assert render_async(lv) =~ "renamed-client"
    end

    test "ignores non-client device changes", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      render_async(lv)

      send(lv.pid, %Change{op: :insert, struct: %Device{type: :gateway}})

      assert has_element?(lv, "#devices-count", "0")
    end
  end

  describe ":show action posture tab" do
    setup do
      account = device_posture_account_fixture()
      actor = admin_actor_fixture(account: account)
      %{account: account, actor: actor}
    end

    test "offers the tab to every device", %{conn: conn, account: account, actor: actor} do
      client = client_fixture(account: account, actor: actor, device_serial: "UNKNOWN-SERIAL")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "phx-value-tab=\"posture\""
    end

    test "says so when a connected provider holds no record for the device", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      intune_posture_provider_fixture(account: account)
      client = client_fixture(account: account, actor: actor, device_serial: "UNKNOWN-SERIAL")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "No posture data was found for this device."
    end

    test "points at connecting a provider when the account has none", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "Connect a posture provider"
      assert html =~ ~p"/#{account}/settings/device_posture/new"
    end

    test "offers an upgrade when the account lacks the feature", %{conn: conn} do
      account = account_fixture(features: %{device_posture: false})
      actor = admin_actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "Upgrade to unlock Device Posture"
      assert html =~ "Upgrade to Unlock"
      refute html =~ "No posture data was found for this device."
    end

    test "still shows the record of a disabled provider", %{conn: conn, account: account, actor: actor} do
      provider = intune_posture_provider_fixture(account: account, name: "Paused Intune", is_disabled: true)
      intune_device_fixture(provider: provider, serial_number: "INTUNE-1234", device_name: "ENG-LAPTOP-02")
      client = client_fixture(account: account, actor: actor, device_serial: "INTUNE-1234")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "Paused Intune"
      assert html =~ "ENG-LAPTOP-02"
      refute html =~ "No posture data was found for this device."
    end

    test "shows the Intune record matched on the attested MDM device id", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = intune_posture_provider_fixture(account: account, name: "Contoso Intune")

      device =
        intune_device_fixture(
          provider: provider,
          intune_id: "managed-device-1",
          device_name: "ENG-LAPTOP-01",
          serial_number: "INTUNE-1234",
          compliance_state: "compliant"
        )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: "managed-device-1",
          last_attested_cert_fingerprint: "fp-1"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "Contoso Intune"
      assert html =~ "Microsoft Intune"
      assert html =~ device.device_name
      assert html =~ "INTUNE-1234"
      assert html =~ "compliant"
      assert html =~ "Attested device ID"
      refute html =~ "Self-reported serial"

      # Columns the summary grid leaves out are still in the copy-paste blob.
      assert html =~ "Raw provider record"
      assert html =~ "Click to expand"
      assert html =~ ~r/id="posture-intune-[^"]+-body" class="relative hidden"/
      assert html =~ "management_agent"
      # Columns the provider left empty are not.
      refute html =~ "android_security_patch_level"
    end

    test "does not match Intune on the Entra device id of a record", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      entra_device_id = Ecto.UUID.generate()
      provider = intune_posture_provider_fixture(account: account)

      intune_device_fixture(
        provider: provider,
        device_name: "ENTRA-JOINED-01",
        entra_device_id: entra_device_id
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: entra_device_id,
          last_attested_cert_fingerprint: "fp-2"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      refute html =~ "ENTRA-JOINED-01"
      assert html =~ "No posture data was found for this device."
    end

    test "cautions when the match rests on the serial the client reports", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = intune_posture_provider_fixture(account: account)

      intune_device_fixture(
        provider: provider,
        device_name: "SELF-REPORTED-01",
        serial_number: "SPOOFABLE-1"
      )

      client = client_fixture(account: account, actor: actor, device_serial: "SPOOFABLE-1")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "SELF-REPORTED-01"
      assert html =~ "Self-reported serial"
      assert html =~ "Matched on a self-reported serial number"
      assert html =~ ~p"/#{account}/settings/trust_anchors"
    end

    test "prefers the attested serial over the reported one", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = iru_posture_provider_fixture(account: account, name: "Iru Prod")

      iru_device_fixture(
        provider: provider,
        device_name: "MACBOOK-01",
        serial_number: "ATTESTED-1"
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "ATTESTED-1",
          device_serial: "ATTESTED-1",
          last_attested_cert_fingerprint: "fp-3"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "Iru Prod"
      assert html =~ "MACBOOK-01"
      assert html =~ "Attested serial"
      refute html =~ "Self-reported serial"
    end

    test "reaches the Defender record through the Intune record's Entra device id", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      entra_device_id = Ecto.UUID.generate()

      intune_device_fixture(
        provider: intune_posture_provider_fixture(account: account, name: "Contoso Intune"),
        intune_id: "managed-device-4",
        entra_device_id: entra_device_id
      )

      defender_device_fixture(
        provider: defender_posture_provider_fixture(account: account, name: "Defender Prod"),
        computer_dns_name: "eng-laptop-01.contoso.com",
        entra_device_id: entra_device_id,
        health_status: "Active"
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: "managed-device-4",
          last_attested_cert_fingerprint: "fp-4"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "Defender Prod"
      assert html =~ "eng-laptop-01.contoso.com"
      assert html =~ "Active"
    end

    test "leaves out a Defender record no Intune record links to the device", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      defender_device_fixture(
        provider: defender_posture_provider_fixture(account: account, name: "Defender Prod"),
        computer_dns_name: "unlinked-laptop.contoso.com",
        entra_device_id: Ecto.UUID.generate()
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: Ecto.UUID.generate(),
          last_attested_cert_fingerprint: "fp-8"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      refute html =~ "unlinked-laptop.contoso.com"
      assert html =~ "No posture data was found for this device."
    end

    test "shows the Santa record matched on serial", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = santa_posture_provider_fixture(account: account, name: "Santa Prod")

      santa_device_fixture(
        provider: provider,
        hostname: "santa-macbook-01",
        serial_number: "SANTA-1"
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "SANTA-1",
          last_attested_cert_fingerprint: "fp-5"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "Santa Prod"
      assert html =~ "santa-macbook-01"
    end

    test "shows the SentinelOne record matched on serial", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = sentinelone_posture_provider_fixture(account: account, name: "S1 Prod")

      sentinelone_device_fixture(
        provider: provider,
        computer_name: "s1-endpoint-01",
        serial_number: "S1-1"
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "S1-1",
          last_attested_cert_fingerprint: "fp-7"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "S1 Prod"
      assert html =~ "s1-endpoint-01"
      assert html =~ "Attested serial"
    end

    test "shows the Sophos record matched on serial", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = sophos_posture_provider_fixture(account: account, name: "Sophos Prod")

      sophos_device_fixture(
        provider: provider,
        hostname: "sophos-mac-01",
        serial_number: "SOPHOS-1",
        health_overall: "suspicious"
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "SOPHOS-1",
          last_attested_cert_fingerprint: "fp-8"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "Sophos Prod"
      assert html =~ "sophos-mac-01"
      assert html =~ "suspicious"
      assert html =~ "Attested serial"
    end

    test "renders one section per provider that knows the device", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      mdm_device_id = Ecto.UUID.generate()

      intune_device_fixture(
        provider: intune_posture_provider_fixture(account: account, name: "Contoso Intune"),
        intune_id: mdm_device_id,
        serial_number: "SHARED-1"
      )

      santa_device_fixture(
        provider: santa_posture_provider_fixture(account: account, name: "Santa Prod"),
        serial_number: "SHARED-1"
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: mdm_device_id,
          last_attested_device_serial: "SHARED-1",
          last_attested_cert_fingerprint: "fp-6"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      assert html =~ "Contoso Intune"
      assert html =~ "Santa Prod"
    end

    test "does not match posture belonging to another account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_account = device_posture_account_fixture()

      intune_posture_provider_fixture(account: account)

      intune_device_fixture(
        provider: intune_posture_provider_fixture(account: other_account),
        device_name: "OTHER-ACCOUNT-01",
        serial_number: "SHARED-SERIAL"
      )

      client = client_fixture(account: account, actor: actor, device_serial: "SHARED-SERIAL")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}?tab=posture")

      refute html =~ "OTHER-ACCOUNT-01"
      assert html =~ "No posture data was found for this device."
    end

    test "does not match a serial against a remote device id", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      intune_device_fixture(
        provider: intune_posture_provider_fixture(account: account),
        intune_id: "COLLIDING-VALUE",
        device_name: "WRONG-COLUMN-01",
        serial_number: "INTUNE-OWN-SERIAL"
      )

      client = client_fixture(account: account, actor: actor, device_serial: "COLLIDING-VALUE")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      refute html =~ "WRONG-COLUMN-01"
    end

  end

  describe "index serial column" do
    setup do
      account = device_posture_account_fixture()
      actor = admin_actor_fixture(account: account)
      %{account: account, actor: actor}
    end

    test "marks an attested serial with the device trust icon", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "ATTESTED-SERIAL-1",
          device_serial: "REPORTED-SERIAL-1"
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert html =~ "ATTESTED-SERIAL-1"
      refute html =~ "REPORTED-SERIAL-1"
      assert has_element?(lv, "#device-#{client.id} .ri-shield-keyhole-line")
    end

    test "marks a serial the MDM holds with that provider's icon", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      intune_device_fixture(
        provider: intune_posture_provider_fixture(account: account),
        intune_id: "managed-device-serial",
        serial_number: "MDM-HELD-SERIAL"
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: "managed-device-serial",
          device_serial: "REPORTED-SERIAL-2"
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert html =~ "MDM-HELD-SERIAL"
      refute html =~ "REPORTED-SERIAL-2"
      assert has_element?(lv, "#device-#{client.id} img[src*='logo-intune']")
      refute has_element?(lv, "#device-#{client.id} .ri-shield-keyhole-line")
    end

    test "leaves a serial the device reports about itself unmarked", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor, device_serial: "REPORTED-SERIAL-3")

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert html =~ "REPORTED-SERIAL-3"
      refute has_element?(lv, "#device-#{client.id} .ri-shield-keyhole-line")
      refute has_element?(lv, "#device-#{client.id} img[src*='logo-intune']")
    end

    test "falls back to the reported serial when the MDM holds none", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: "managed-device-unknown",
          device_serial: "REPORTED-SERIAL-4"
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert html =~ "REPORTED-SERIAL-4"
      refute has_element?(lv, "#device-#{client.id} .ri-shield-keyhole-line")
    end

    test "leaves the column empty for a device with no serial at all", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor, device_serial: nil)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert html =~ client.slug
      refute has_element?(lv, "#device-#{client.id} .ri-shield-keyhole-line")
    end
  end

  describe ":show action certificate section" do
    test "omits the section for a client that never attested", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      refute html =~ "SHA-256 Fingerprint"
    end

    test "reports an unknown status when nothing has been published", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_cert_fingerprint: "ab:cd",
          last_attested_cert_serial: "01",
          last_attested_cert_issuer: issuer_der("Unpublished CA")
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "SHA-256 Fingerprint"
      assert html =~ "Unpublished CA"
      assert html =~ "Unknown"
    end

    test "reports a revoked certificate from the issuer's list", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      issuer = issuer_der("Revoking CA")

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_cert_fingerprint: "ab:cd",
          last_attested_cert_serial: "02",
          last_attested_cert_issuer: issuer
        )

      Repo.insert!(%Portal.CrlRevocation{
        account_id: account.id,
        issuer: issuer,
        serial: "02",
        distribution_point: "http://crl.example.test/ca.crl",
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        reason: "keyCompromise"
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Revoked"
      assert html =~ "keyCompromise"
    end

    test "reports a good certificate from the issuer's responder", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      issuer = issuer_der("Responding CA")

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_cert_fingerprint: "ab:cd",
          last_attested_cert_serial: "03",
          last_attested_cert_issuer: issuer
        )

      Repo.insert!(%Portal.OcspStatus{
        account_id: account.id,
        issuer: issuer,
        serial: "03",
        status: "good",
        next_update: DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second),
        updated_at: DateTime.utc_now()
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Valid"
    end

    test "a published revocation outranks a responder that still says good", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      issuer = issuer_der("Disagreeing CA")

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_cert_fingerprint: "ab:cd",
          last_attested_cert_serial: "04",
          last_attested_cert_issuer: issuer
        )

      Repo.insert!(%Portal.OcspStatus{
        account_id: account.id,
        issuer: issuer,
        serial: "04",
        status: "good",
        updated_at: DateTime.utc_now()
      })

      Repo.insert!(%Portal.CrlRevocation{
        account_id: account.id,
        issuer: issuer,
        serial: "04",
        distribution_point: "http://crl.example.test/ca.crl",
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert html =~ "Revoked"
      refute html =~ "Valid"
    end
  end

  defp issuer_der(common_name) do
    :public_key.der_encode(
      :Name,
      {:rdnSequence,
       [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, common_name}}]]}
    )
  end
  describe "live table filters across panel operations" do
    setup %{account: account, actor: actor} do
      matching = client_fixture(account: account, actor: actor, name: "laptop-alpha")
      other = client_fixture(account: account, actor: actor, name: "desktop-beta")
      filter = %{"devices_filter[search]" => "laptop"}
      %{matching: matching, other: other, filter: filter}
    end

    test "are kept when editing a device", %{
      conn: conn,
      account: account,
      actor: actor,
      matching: matching,
      other: other,
      filter: filter
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{matching.id}?#{filter}")

      refute html =~ other.name

      render_click(lv, "open_device_edit_form")
      assert_patch(lv, ~p"/#{account}/devices/#{matching.id}/edit?#{filter}")

      render_click(lv, "cancel_device_edit_form")
      assert_patch(lv, ~p"/#{account}/devices/#{matching.id}?#{filter}")

      render_click(lv, "open_device_edit_form")

      lv
      |> form("[phx-submit='submit_device_edit_form']", device: %{name: "laptop-renamed"})
      |> render_submit()

      assert_patch(lv, ~p"/#{account}/devices/#{matching.id}?#{filter}")

      html = render(lv)
      assert html =~ "laptop-renamed"
      refute html =~ other.name

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/devices?#{filter}")
    end
  end

  describe "events queued after the panel closes" do
    for {event, params} <- [
          {"change_policy_authorizations_page", %{"page" => "2"}},
          {"open_device_edit_form", %{}},
          {"cancel_device_edit_form", %{}},
          {"change_device_edit_form", %{"device" => %{"name" => "Late"}}},
          {"submit_device_edit_form", %{"device" => %{"name" => "Late"}}},
          {"verify_device", %{}},
          {"unverify_device", %{}},
          {"delete_device", %{}}
        ] do
      test "ignores #{event}", %{conn: conn, account: account, actor: actor} do
        client = client_fixture(account: account, actor: actor)

        {:ok, lv, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/devices/#{client.id}/edit")

        render_click(lv, "close_panel")
        assert_patch(lv, ~p"/#{account}/devices")

        render_click(lv, unquote(event), unquote(Macro.escape(params)))

        assert render(lv) =~ "Devices"
        device = Repo.get_by(Device, account_id: account.id, id: client.id)
        assert device.name == client.name
        assert device.verified_at == client.verified_at
      end
    end
  end

  describe ":show action site section" do
    test "is hidden without the unified devices feature", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)
      site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      refute has_element?(lv, "#device-site")
    end

    test "adds the device to a site", %{conn: conn, account: account, actor: actor} do
      put_unified_devices(account, true)
      client = client_fixture(account: account, actor: actor)
      Repo.update_all(from(d in Device, where: d.id == ^client.id), set: [type: nil])
      site = internet_site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert has_element?(lv, "#device-site-form option[value='#{site.id}']", site.name)

      html =
        lv
        |> form("#device-site-form", site_device: %{site_id: site.id})
        |> render_submit()

      assert html =~ "Device added to the site."
      assert has_element?(lv, "#device-site a", site.name)
      refute has_element?(lv, "#device-site-form")

      assert Repo.get_by(Portal.SiteDevice,
               account_id: account.id,
               site_id: site.id,
               device_id: client.id
             )
    end

    test "removes the device from its site with the authorizations for that site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      put_unified_devices(account, true)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      other_site = site_fixture(account: account)

      Repo.insert!(%Portal.SiteDevice{
        account_id: account.id,
        site_id: site.id,
        device_id: client.id
      })

      served =
        policy_authorization_fixture(
          account: account,
          gateway: client,
          resource: resource_fixture(account: account, site: site)
        )

      unrelated =
        policy_authorization_fixture(
          account: account,
          gateway: client,
          resource: resource_fixture(account: account, site: other_site)
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert has_element?(lv, "#device-site a", site.name)

      html =
        lv
        |> element("#device-site button", "Remove from site")
        |> render_click()

      assert html =~ "Device removed from the site."
      assert has_element?(lv, "#device-site-form")
      refute Repo.get_by(Portal.SiteDevice, account_id: account.id, device_id: client.id)
      refute Repo.get_by(Portal.PolicyAuthorization, account_id: account.id, id: served.id)
      assert Repo.get_by(Portal.PolicyAuthorization, account_id: account.id, id: unrelated.id)
    end

    test "does not put a device last seen on /client in a site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      put_unified_devices(account, true)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      assert has_element?(lv, "#device-site", "Update to the latest Firezone client to route for a site.")
      assert has_element?(lv, "#device-site-form select[disabled]")
      assert has_element?(lv, "#device-site-form button[disabled]")

      html = render_hook(lv, "put_device_in_site", %{"site_device" => %{"site_id" => site.id}})

      assert html =~ "Could not add the device to the site."
      refute Repo.get_by(Portal.SiteDevice, account_id: account.id, device_id: client.id)
    end

    test "shows the site section only to accounts with unified_devices set to true", %{conn: conn} do
      for {value, shown?} <- [{true, true}, {false, false}, {nil, false}] do
        account = put_unified_devices(account_fixture(), value)
        actor = admin_actor_fixture(account: account)
        client = client_fixture(account: account, actor: actor)

        {:ok, lv, _html} =
          conn
          |> authorize_conn(actor)
          |> live(~p"/#{account}/devices/#{client.id}")

        assert has_element?(lv, "#device-site") == shown?
      end
    end

    test "ignores site events without the unified devices feature", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{client.id}")

      render_hook(lv, "put_device_in_site", %{"site_device" => %{"site_id" => site.id}})

      refute Repo.get_by(Portal.SiteDevice, account_id: account.id, device_id: client.id)
    end
  end

  describe "unified devices list" do
    setup %{account: account, actor: actor} do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site, token: :single_owner)
      client = client_fixture(account: account, actor: actor)
      %{site: site, gateway: gateway, client: client}
    end

    test "lists only clients without the flag", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway: gateway,
      client: client
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert has_element?(lv, "#device-#{client.id}")
      refute has_element?(lv, "#device-#{gateway.id}")
      refute has_element?(lv, "#devices th", "Site")
      refute has_element?(lv, "#devices-site_id")
      refute has_element?(lv, "#devices-has_users-toggle")
    end

    test "ignores a site filter in the URL without the flag", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      client: client
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices?#{%{"devices_filter[site_id]" => site.id}}")

      assert has_element?(lv, "#device-#{client.id}")
    end

    test "does not open a gateway panel without the flag", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway: gateway
    } do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/devices/#{gateway.id}")

      assert to == ~p"/#{account}/devices"
      assert flash["error"] == "Device does not exist."
    end

    test "lists gateways with their label and site", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      gateway: gateway,
      client: client
    } do
      put_unified_devices(account, true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert has_element?(lv, "th", "Owner or site")
      assert has_element?(lv, "#device-#{gateway.id}", "Gateway")
      assert has_element?(lv, "#device-#{gateway.id} a[href='/#{account.slug}/sites/#{site.id}']", site.name)
      assert has_element?(lv, "#device-#{client.id}")
      refute has_element?(lv, "#device-#{client.id}", "Gateway")
      refute has_element?(lv, "#device-#{client.id} a[href='/#{account.slug}/sites/#{site.id}']")
      render_async(lv)
      assert has_element?(lv, "#devices-count", "2")
    end

    test "shows the site of a client that routes for one", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      client: client
    } do
      put_unified_devices(account, true)
      Repo.insert!(%Portal.SiteDevice{account_id: account.id, site_id: site.id, device_id: client.id})

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      assert has_element?(lv, "#device-#{client.id} a[href='/#{account.slug}/sites/#{site.id}']", site.name)
    end

    test "filters by the site a device routes for", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      gateway: gateway,
      client: client
    } do
      put_unified_devices(account, true)
      other_site = site_fixture(account: account)
      other_gateway = gateway_fixture(account: account, site: other_site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices?#{%{"devices_filter[site_id]" => site.id}}")

      assert has_element?(lv, "#devices-site_id option[value='#{site.id}']", site.name)
      assert has_element?(lv, "#devices-site_id option[value='#{other_site.id}']", other_site.name)
      assert has_element?(lv, "#device-#{gateway.id}")
      refute has_element?(lv, "#device-#{other_gateway.id}")
      refute has_element?(lv, "#device-#{client.id}")
    end

    test "filters for devices with users, which leaves out gateways", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway: gateway,
      client: client
    } do
      put_unified_devices(account, true)
      conn = authorize_conn(conn, actor)

      {:ok, lv, _html} =
        live(conn, ~p"/#{account}/devices?#{%{"devices_filter[has_users]" => "true"}}")

      assert has_element?(lv, "#devices-has_users-toggle")
      assert has_element?(lv, "#device-#{client.id}")
      refute has_element?(lv, "#device-#{gateway.id}")

      {:ok, lv, _html} =
        live(conn, ~p"/#{account}/devices?#{%{"devices_filter[has_users]" => "false"}}")

      assert has_element?(lv, "#device-#{client.id}")
      assert has_element?(lv, "#device-#{gateway.id}")
    end

    test "counts gateways as online", %{conn: conn, account: account, actor: actor, gateway: gateway, client: client} do
      put_unified_devices(account, true)
      :ok = Portal.Presence.Devices.Account.track(gateway)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices?#{%{"devices_filter[presence]" => "online"}}")

      assert has_element?(lv, "#device-#{gateway.id}")
      refute has_element?(lv, "#device-#{client.id}")
    end

    test "shows what applies to a gateway in its panel", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      gateway: gateway
    } do
      put_unified_devices(account, true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{gateway.id}")

      assert has_element?(lv, "#device-panel h2", gateway.slug)
      assert has_element?(lv, "#device-panel", "Gateway")
      assert has_element?(lv, "#gateway-site a[href='/#{account.slug}/sites/#{site.id}']", site.name)
      assert has_element?(lv, "#gateway-site", "Last connected with gateway token")
      assert has_element?(lv, "#device-panel", "Rename gateway")
      assert has_element?(lv, "#device-panel", "Rotate token")
      assert has_element?(lv, "#device-panel", "Delete gateway")
      assert has_element?(lv, "#device-panel", "Remote IP")
      assert has_element?(lv, "#device-panel", gateway.last_seen_version)

      refute has_element?(lv, "#device-panel button", "Verify")
      refute has_element?(lv, "#device-panel", "Trust level")
      refute has_element?(lv, "#device-panel [phx-value-tab='posture']")
      refute has_element?(lv, "#device-panel", "Reported by Client")
      refute has_element?(lv, "#device-panel button", "Edit")
      refute has_element?(lv, "#device-site-form")
    end

    test "ignores client-only events for a gateway", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      gateway: gateway
    } do
      put_unified_devices(account, true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{gateway.id}")

      render_click(lv, "verify_device")
      render_click(lv, "remove_device_from_site")

      gateway = Repo.get_by!(Device, account_id: account.id, id: gateway.id)
      assert is_nil(gateway.verified_at)
      assert Repo.get_by(Portal.SiteDevice, account_id: account.id, site_id: site.id, device_id: gateway.id)
    end

    test "sends the edit route of a gateway back to its panel", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway: gateway
    } do
      put_unified_devices(account, true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{gateway.id}")

      render_patch(lv, ~p"/#{account}/devices/#{gateway.id}/edit")
      assert_patch(lv, ~p"/#{account}/devices/#{gateway.id}")
      refute has_element?(lv, "#device-edit-form")
    end

    test "renames a gateway as the Sites page does", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway: gateway
    } do
      put_unified_devices(account, true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{gateway.id}")

      render_click(lv, "rename_gateway")
      assert has_element?(lv, "#rename-gateway-#{gateway.id}")

      html = render_submit(lv, "save_gateway_name", %{"name" => "  edge-nyc-1 "})
      assert html =~ "Gateway renamed."
      refute has_element?(lv, "#rename-gateway-#{gateway.id}")
      assert has_element?(lv, "#device-panel", "edge-nyc-1")

      assert Repo.get_by!(Device, account_id: account.id, id: gateway.id).name == "edge-nyc-1"

      render_click(lv, "rename_gateway")
      html = render_submit(lv, "save_gateway_name", %{"name" => "   "})
      assert html =~ "Failed to rename gateway."
      assert Repo.get_by!(Device, account_id: account.id, id: gateway.id).name == "edge-nyc-1"
    end

    test "rotates a gateway token as the Sites page does", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway: gateway
    } do
      put_unified_devices(account, true)
      token = Repo.get_by!(Portal.DeviceToken, account_id: account.id, device_id: gateway.id)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{gateway.id}")

      html = render_click(lv, "rotate_gateway_token")
      assert html =~ "Rotate this gateway&#39;s token?"

      html = render_click(lv, "cancel_rotate_gateway_token")
      refute html =~ "Rotate this gateway&#39;s token?"

      render_click(lv, "rotate_gateway_token")
      html = render_click(lv, "confirm_rotate_gateway_token")
      assert html =~ "Token rotated."
      assert html =~ "New gateway token"
      assert html =~ "The expiring token keeps working"
      assert has_element?(lv, "[data-copy-to-clipboard-target='gateway-token-reveal-#{gateway.id}-code']")
      refute has_element?(lv, "#device-panel button", "Rotate token")

      assert html =~
               "Last connected with expiring gateway token - Replacement provisioned, but never used"

      assert Repo.get_by!(Portal.DeviceToken, account_id: account.id, id: token.id).rotated_at

      html = render_click(lv, "dismiss_rotated_gateway_token")
      refute html =~ "Copy it now"
    end

    test "deletes a gateway as the Sites page does", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway: gateway
    } do
      put_unified_devices(account, true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices/#{gateway.id}")

      html = render_click(lv, "confirm_delete_device")
      assert html =~ "Delete this gateway?"
      refute html =~ "disable the owning actor"

      html = render_click(lv, "delete_device")
      assert html =~ "Gateway deleted."
      assert_patch(lv, ~p"/#{account}/devices")

      refute Repo.get_by(Device, account_id: account.id, id: gateway.id)
      refute Repo.get_by(Portal.DeviceToken, account_id: account.id, device_id: gateway.id)
      render_async(lv)
      refute has_element?(lv, "#device-#{gateway.id}")
    end

    test "shows gateway changes as they happen", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      gateway: gateway
    } do
      put_unified_devices(account, true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      refute has_element?(lv, "#devices-reload-btn")

      new_gateway = gateway_fixture(account: account, site: site)
      send(lv.pid, %Change{op: :insert, struct: new_gateway})

      assert has_element?(lv, "#devices-reload-btn")
      render_click(lv, "reload", %{"table_id" => "devices"})
      render_async(lv)
      assert has_element?(lv, "#device-#{new_gateway.id}", "Gateway")

      Repo.delete!(gateway)
      send(lv.pid, %Change{op: :delete, old_struct: gateway})

      assert has_element?(lv, "#devices-reload-btn")
      render_click(lv, "reload", %{"table_id" => "devices"})
      render_async(lv)
      refute has_element?(lv, "#device-#{gateway.id}")
    end

    test "ignores gateway changes without the flag", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/devices")

      new_gateway = gateway_fixture(account: account, site: site)
      send(lv.pid, %Change{op: :insert, struct: new_gateway})
      send(lv.pid, %Change{op: :delete, old_struct: new_gateway})

      refute has_element?(lv, "#devices-reload-btn")
      refute has_element?(lv, "#device-#{new_gateway.id}")
    end

    test "shows nothing new to another account without the flag", %{
      conn: conn,
      account: account
    } do
      put_unified_devices(account, true)

      other_account = account_fixture()
      other_actor = admin_actor_fixture(account: other_account)
      other_gateway = gateway_fixture(account: other_account)
      other_client = client_fixture(account: other_account, actor: other_actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(other_actor)
        |> live(~p"/#{other_account}/devices")

      assert has_element?(lv, "#device-#{other_client.id}")
      refute has_element?(lv, "#device-#{other_gateway.id}")
      refute has_element?(lv, "#devices th", "Site")
      refute has_element?(lv, "#devices-site_id")
      refute has_element?(lv, "#devices-has_users-toggle")
    end
  end
end
