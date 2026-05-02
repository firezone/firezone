defmodule PortalWeb.ClientsTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.{Device, Repo}

  import Portal.AccountFixtures
  import Portal.ActorFixtures
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
      assert html =~ "Verified 1"
      assert html =~ "Unverified 1"
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
      assert html =~ "Tunnel IPv4"
      assert html =~ "Tunnel IPv6"
      assert html =~ "Verified"
      assert html =~ session.version

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/clients")
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

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/clients/#{client.id}?tab=authorizations")

      assert html =~ "No recent authorizations"
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
end
