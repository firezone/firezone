defmodule PortalWeb.ClientsTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.{Device, Repo}
  alias Portal.Changes.Change

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DefenderFixtures
  import Portal.IntuneFixtures
  import Portal.IruFixtures
  import Portal.SantaFixtures
  import Portal.SentinelOneFixtures
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
      path = ~p"/#{account}/clients"

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
    test "renders empty state when no clients exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients")

      assert html =~ "Clients"
      assert html =~ "No clients yet"
    end

    test "renders client list page", %{conn: conn, account: account, actor: actor} do
      client = client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients")

      assert html =~ "Clients"
      assert html =~ client.name
    end

    test "filters clients by client name or actor name/email", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      owner = actor_fixture(account: account, name: "Owner Person", email: "owner@example.com")
      client = client_fixture(account: account, actor: owner, name: "Owner Laptop")
      other_client = client_fixture(account: account, actor: actor, name: "Other Laptop")

      conn = authorize_conn(conn, actor)

      for search <- [client.name, owner.name, owner.email] do
        {:ok, _lv, html} =
          live(conn, ~p"/#{account}/clients?#{%{"clients_filter[search]" => search}}")

        assert html =~ client.name
        refute html =~ other_client.name
      end
    end

    test "renders verified and unverified client states", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      verified_actor = actor_fixture(account: account, name: "Verified Owner")

      verified_client =
        verified_client_fixture(%{account: account, actor: verified_actor, name: "Work Mac"})

      unverified_client = client_fixture(account: account, actor: actor, name: "Lab Box")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients")

      html = render(lv)
      assert html =~ verified_client.name
      assert html =~ unverified_client.name
      assert has_element?(lv, "#client-#{verified_client.id}", "Verified")
      assert has_element?(lv, "#client-#{unverified_client.id}", "Unverified")
    end

    test "orders by name and opens the panel from row click", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      alpha = client_fixture(account: account, actor: actor, name: "Alpha Client")
      omega = client_fixture(account: account, actor: actor, name: "Omega Client")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients")

      html =
        element(
          lv,
          "button[phx-click='order_by'][phx-value-table_id='clients'][phx-value-order_by='devices:asc:name']"
        )
        |> render_click()

      assert html =~ alpha.name
      assert html =~ omega.name
      assert elem(:binary.match(html, omega.name), 0) < elem(:binary.match(html, alpha.name), 0)

      render_click(element(lv, "#client-#{omega.id}"))

      assert_patch(
        lv,
        ~p"/#{account}/clients/#{omega.id}?#{%{clients_order_by: "devices:desc:name"}}"
      )

      assert render(lv) =~ omega.name
    end
  end

  describe ":show action" do
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
        |> live(~p"/#{account}/clients/#{client.id}")

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
      assert html =~ "Verification"
      assert html =~ "Verified"
      assert html =~ session.last_seen_version

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/clients")
    end

    test "lists the device pools the client belongs to", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      pool =
        static_device_pool_resource_fixture(
          account: account,
          name: "Engineering Laptops",
          clients: [client]
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients/#{client.id}")

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
        |> live(~p"/#{account}/clients/#{client.id}")

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
        |> live(~p"/#{account}/clients/#{client.id}")

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/clients")

      render_click(lv, "switch_client_tab", %{"tab" => "authorizations"})

      refute has_element?(lv, "#client-panel > div")
    end

    test "marks only older client versions as outdated" do
      older_html =
        render_component(&PortalWeb.Clients.Components.version/1,
          current: "0.9.0",
          latest: "1.0.0"
        )

      assert older_html =~ "A newer version"
      assert older_html =~ "1.0.0"

      latest_html =
        render_component(&PortalWeb.Clients.Components.version/1,
          current: "1.0.0",
          latest: "1.0.0"
        )

      assert latest_html =~ "This component is up to date."
      refute latest_html =~ "A newer version"

      newer_html =
        render_component(&PortalWeb.Clients.Components.version/1,
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
        |> live(~p"/#{account}/clients/#{client.id}")

      html = render_click(lv, "confirm_delete_client")
      assert html =~ "Delete this client?"

      html = render_click(lv, "cancel_delete_client")
      refute html =~ "Delete this client?"

      render_click(lv, "confirm_delete_client")
      render_click(lv, "delete_client")

      assert_patch(lv, ~p"/#{account}/clients")
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
        |> live(~p"/#{account}/clients/#{client.id}")

      assert has_element?(lv, "button[phx-click='verify_client']", "Verify")

      html = render_click(lv, "verify_client")
      updated_client = Repo.get_by!(Device, account_id: account.id, id: client.id)

      assert html =~ "Client &quot;#{client.name}&quot; was verified."
      assert html =~ "Verified"
      assert updated_client.verified_at
      refute has_element?(lv, "button[phx-click='verify_client']", "Verify")
      assert has_element?(
               lv,
               "button[phx-click='confirm_unverify_client']",
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
        |> live(~p"/#{account}/clients/#{client.id}")

      html = render_click(lv, "confirm_unverify_client")
      assert html =~ "Revoke verification for this client?"
      assert html =~ "Current authorizations for this client may be revoked."

      html = render_click(lv, "cancel_unverify_client")
      updated_client = Repo.get_by!(Device, account_id: account.id, id: client.id)

      refute html =~ "Revoke verification for this client?"
      assert updated_client.verified_at
      assert has_element?(
               lv,
               "button[phx-click='confirm_unverify_client']",
               "Revoke verification"
             )

      refute has_element?(lv, "button[phx-click='verify_client']", "Verify")
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
        |> live(~p"/#{account}/clients/#{client.id}")

      render_click(lv, "confirm_unverify_client")
      html = render_click(lv, "unverify_client")
      updated_client = Repo.get_by!(Device, account_id: account.id, id: client.id)

      assert html =~ "Client &quot;#{client.name}&quot; was unverified."
      refute html =~ "Revoke verification for this client?"
      assert is_nil(updated_client.verified_at)
      assert has_element?(lv, "button[phx-click='verify_client']", "Verify")
      refute has_element?(
               lv,
               "button[phx-click='confirm_unverify_client']",
               "Revoke verification"
             )
    end

    test "patches to clients index with flash when client does not exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      missing_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/clients/#{missing_id}")

      assert to == ~p"/#{account}/clients"
      assert flash["error"] =~ "Client does not exist"
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
        |> live(~p"/#{account}/clients/#{client.id}/edit")

      assert html =~ "Edit Client"
      assert html =~ "Save"
      assert html =~ client.name
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
        |> live(~p"/#{account}/clients/#{client.id}")

      render_click(lv, "open_client_edit_form")
      assert_patch(lv, ~p"/#{account}/clients/#{client.id}/edit")

      html =
        lv
        |> form("[phx-submit='submit_client_edit_form']", device: %{name: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"

      render_click(lv, "cancel_client_edit_form")
      assert_patch(lv, ~p"/#{account}/clients/#{client.id}")

      render_click(lv, "open_client_edit_form")

      html =
        lv
        |> form("[phx-submit='submit_client_edit_form']", device: %{name: "Updated Client Name"})
        |> render_submit()

      updated_client = Repo.get_by!(Device, account_id: account.id, id: client.id)

      assert html =~ "Client updated successfully."
      assert html =~ "Updated Client Name"
      assert updated_client.name == "Updated Client Name"
      assert_patch(lv, ~p"/#{account}/clients/#{client.id}")
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
        |> live(~p"/#{account}/clients/#{client.id}")

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
        |> live(~p"/#{account}/clients/#{client.id}")

      lv
      |> element("button[phx-click='switch_client_tab'][phx-value-tab='authorizations']")
      |> render_click()

      assert_patch(lv, ~p"/#{account}/clients/#{client.id}?tab=authorizations")
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
        |> live(~p"/#{account}/clients/#{client.id}?tab=authorizations")

      lv
      |> element("button[phx-click='switch_client_tab'][phx-value-tab='overview']")
      |> render_click()

      assert_patch(lv, ~p"/#{account}/clients/#{client.id}?tab=overview")
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
        |> live(~p"/#{account}/clients/#{client.id}?tab=authorizations")

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
        |> live(~p"/#{account}/clients/#{client.id}?tab=authorizations")

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
        |> live(~p"/#{account}/clients/#{client.id}")

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
        |> live(~p"/#{account}/clients")

      assert html =~ "Loading..."

      html = render_async(lv)

      assert html =~ "1"
      assert html =~ "Total"
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
        |> live(~p"/#{account}/clients")

      render_async(lv)

      send(lv.pid, %Change{op: :insert, struct: %Device{type: :client}})

      html = render(lv)
      assert html =~ "1"
      assert html =~ "Total"
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
        |> live(~p"/#{account}/clients")

      render_async(lv)

      send(lv.pid, %Change{op: :delete, old_struct: %Device{type: :client}})

      html = render(lv)
      assert html =~ "0"
      assert html =~ "Total"
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
        |> live(~p"/#{account}/clients")

      render_async(lv)
      refute has_element?(lv, "#clients-reload-btn")

      {:ok, _updated} =
        client
        |> Ecto.Changeset.change(name: "Renamed Client")
        |> Repo.update()

      send(lv.pid, %Change{op: :update, struct: %Device{type: :client, id: client.id}})

      assert has_element?(lv, "#clients-reload-btn")

      render_click(lv, "reload", %{"table_id" => "clients"})
      assert render(lv) =~ "Renamed Client"
    end

    test "ignores non-client device changes", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients")

      render_async(lv)

      send(lv.pid, %Change{op: :insert, struct: %Device{type: :gateway}})

      html = render(lv)
      assert html =~ "0"
      assert html =~ "Total"
    end
  end

  describe ":show action posture tab" do
    test "hides the tab when no posture provider knows this client", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor, device_serial: "UNKNOWN-SERIAL")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients/#{client.id}")

      refute html =~ "phx-value-tab=\"posture\""
    end

    test "falls back to the overview when the tab is requested with no posture", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients/#{client.id}?tab=posture")

      assert html =~ "Tunnel IPv4"
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
        |> live(~p"/#{account}/clients/#{client.id}?tab=posture")

      assert html =~ "Contoso Intune"
      assert html =~ "Microsoft Intune"
      assert html =~ device.device_name
      assert html =~ "INTUNE-1234"
      assert html =~ "compliant"
      assert html =~ "Attested device ID"
      refute html =~ "Reported serial"

      # Columns the summary grid leaves out are still in the copy-paste blob.
      assert html =~ "Provider record"
      assert html =~ "management_agent"
      # Columns the provider left empty are not.
      refute html =~ "android_security_patch_level"
    end

    test "matches Intune on the Entra device id the certificate attested", %{
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
        |> live(~p"/#{account}/clients/#{client.id}?tab=posture")

      assert html =~ "ENTRA-JOINED-01"
      assert html =~ "Attested device ID"
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
        |> live(~p"/#{account}/clients/#{client.id}?tab=posture")

      assert html =~ "SELF-REPORTED-01"
      assert html =~ "Reported serial"
      assert html =~ "spoofed by a malicious actor"
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
        |> live(~p"/#{account}/clients/#{client.id}?tab=posture")

      assert html =~ "Iru Prod"
      assert html =~ "MACBOOK-01"
      assert html =~ "Attested serial"
      refute html =~ "Reported serial"
    end

    test "shows the Defender record matched on the attested Entra device id", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      entra_device_id = Ecto.UUID.generate()
      provider = defender_posture_provider_fixture(account: account, name: "Defender Prod")

      defender_device_fixture(
        provider: provider,
        computer_dns_name: "eng-laptop-01.contoso.com",
        entra_device_id: entra_device_id,
        health_status: "Active"
      )

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: entra_device_id,
          last_attested_cert_fingerprint: "fp-4"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients/#{client.id}?tab=posture")

      assert html =~ "Defender Prod"
      assert html =~ "eng-laptop-01.contoso.com"
      assert html =~ "Active"
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
        |> live(~p"/#{account}/clients/#{client.id}?tab=posture")

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
        |> live(~p"/#{account}/clients/#{client.id}?tab=posture")

      assert html =~ "S1 Prod"
      assert html =~ "s1-endpoint-01"
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
        |> live(~p"/#{account}/clients/#{client.id}?tab=posture")

      assert html =~ "Contoso Intune"
      assert html =~ "Santa Prod"
    end

    test "does not match posture belonging to another account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_account = account_fixture()

      intune_device_fixture(
        provider: intune_posture_provider_fixture(account: other_account),
        device_name: "OTHER-ACCOUNT-01",
        serial_number: "SHARED-SERIAL"
      )

      client = client_fixture(account: account, actor: actor, device_serial: "SHARED-SERIAL")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients/#{client.id}")

      refute html =~ "OTHER-ACCOUNT-01"
      refute html =~ "phx-value-tab=\"posture\""
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
        |> live(~p"/#{account}/clients/#{client.id}")

      refute html =~ "WRONG-COLUMN-01"
    end

    test "badges the providers that know each client in the list", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      intune_device_fixture(
        provider: intune_posture_provider_fixture(account: account),
        serial_number: "LIST-SERIAL-1"
      )

      client_fixture(
        account: account,
        actor: actor,
        name: "Inventoried Client",
        device_serial: "LIST-SERIAL-1"
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients")

      assert html =~ "logo-intune.svg"
    end

    test "leaves the list badge empty for a client no provider knows", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      intune_posture_provider_fixture(account: account)
      client_fixture(account: account, actor: actor, device_serial: "NOT-IN-INVENTORY")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients")

      refute html =~ "logo-intune.svg"
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
        |> live(~p"/#{account}/clients/#{client.id}")

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
        |> live(~p"/#{account}/clients/#{client.id}")

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
        |> live(~p"/#{account}/clients/#{client.id}")

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
        |> live(~p"/#{account}/clients/#{client.id}")

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
        |> live(~p"/#{account}/clients/#{client.id}")

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
end
