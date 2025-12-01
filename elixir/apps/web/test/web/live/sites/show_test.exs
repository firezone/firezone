defmodule Web.Live.Sites.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    site = Fixtures.Sites.create_site(account: account, subject: subject)
    gateway = Fixtures.Gateways.create_gateway(account: account, site: site)
    gateway = Repo.preload(gateway, :site)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      site: site,
      gateway: gateway
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    site: site,
    conn: conn
  } do
    path = ~p"/#{account}/sites/#{site}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "raises NotFoundError for deleted site", %{
    account: account,
    site: site,
    identity: identity,
    conn: conn
  } do
    {:ok, deleted_site} = Fixtures.Sites.delete_site(site)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{deleted_site}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    site: site,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{site}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
    assert breadcrumbs =~ site.name
  end

  describe "for non-managed sites" do
    test "allows editing gateway sites", %{
      account: account,
      site: site,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      assert lv
             |> element("a", "Edit Site")
             |> render_click() ==
               {:error, {:live_redirect, %{to: ~p"/#{account}/sites/#{site}/edit", kind: :push}}}
    end

    test "renders site details", %{
      account: account,
      actor: actor,
      identity: identity,
      site: site,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      table =
        lv
        |> element("#site")
        |> render()
        |> vertical_table_to_map()

      assert table["name"] =~ site.name
      assert table["created"] =~ actor.name
    end

    test "renders site details when site created by API", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(type: :api_client, account: account)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor)
      site = Fixtures.Sites.create_site(account: account, subject: subject)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      table =
        lv
        |> element("#site")
        |> render()
        |> vertical_table_to_map()

      assert table["name"] =~ site.name
      assert table["created"] =~ actor.name
    end

    test "renders online gateways table", %{
      account: account,
      identity: identity,
      site: site,
      gateway: gateway,
      conn: conn
    } do
      site_token = Fixtures.Sites.create_token(site: gateway.site, account: account)
      :ok = Domain.Presence.Gateways.connect(gateway, site_token.id)
      Fixtures.Gateways.create_gateway(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      rows =
        lv
        |> element("#gateways")
        |> render()
        |> table_to_map()

      assert length(rows) == 1

      rows
      |> with_table_row("instance", gateway.name, fn row ->
        assert gateway.last_seen_remote_ip
        assert row["remote ip"] =~ to_string(gateway.last_seen_remote_ip)
        assert row["version"] =~ gateway.last_seen_version
        assert row["status"] =~ "Online"
      end)
    end

    test "updates online gateways table", %{
      account: account,
      site: site,
      gateway: gateway,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      :ok = Domain.Presence.Gateways.Site.subscribe(site.id)
      gateway_token = Fixtures.Sites.create_token(site: gateway.site, account: account)
      :ok = Domain.Presence.Gateways.connect(gateway, gateway_token.id)
      assert_receive %Phoenix.Socket.Broadcast{topic: "presences:sites:#{gateway.site.id}"}

      wait_for(fn ->
        lv
        |> element("#gateways")
        |> render()
        |> table_to_map()
        |> with_table_row("instance", gateway.name, fn row ->
          assert row["status"] =~ "Online"
        end)
      end)
    end

    test "allows revoking all tokens", %{
      account: account,
      site: site,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      assert lv
             |> element("button[type=submit]", "Revoke All")
             |> render_click() =~ "1 token(s) were revoked."

      refute Repo.get_by(Domain.Token, site_id: site.id)
    end

    test "renders resources table", %{
      account: account,
      identity: identity,
      site: site,
      conn: conn
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{site_id: site.id}]
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      resource_rows =
        lv
        |> element("#resources")
        |> render()
        |> table_to_map()

      Enum.each(resource_rows, fn row ->
        assert row["name"] =~ resource.name
        assert row["address"] =~ resource.address
        assert row["authorized groups"] == "None. Create a Policy to grant access."
      end)
    end

    test "renders authorized groups peek", %{
      account: account,
      identity: identity,
      site: site,
      conn: conn
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{site_id: site.id}]
        )

      policies =
        [
          Fixtures.Policies.create_policy(
            account: account,
            resource: resource
          ),
          Fixtures.Policies.create_policy(
            account: account,
            resource: resource
          ),
          Fixtures.Policies.create_policy(
            account: account,
            resource: resource
          )
        ]
        |> Repo.preload(:actor_group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      resource_rows =
        lv
        |> element("#resources")
        |> render()
        |> table_to_map()

      Enum.each(resource_rows, fn row ->
        for policy <- policies do
          assert row["authorized groups"] =~ policy.actor_group.name
        end
      end)

      Fixtures.Policies.create_policy(
        account: account,
        resource: resource
      )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      resource_rows =
        lv
        |> element("#resources")
        |> render()
        |> table_to_map()

      Enum.each(resource_rows, fn row ->
        assert row["authorized groups"] =~ "and 1 more"
      end)
    end

    test "allows deleting sites", %{
      account: account,
      site: site,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      lv
      |> element("button[type=submit]", "Delete")
      |> render_click()

      assert_redirected(lv, ~p"/#{account}/sites")

      refute Repo.get(Domain.Site, site.id)
    end
  end

  describe "for non-internet resources" do
    test "allows editing sites", %{
      account: account,
      site: site,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      assert lv
             |> element("a", "Edit Site")
             |> render_click() ==
               {:error, {:live_redirect, %{to: ~p"/#{account}/sites/#{site}/edit", kind: :push}}}
    end

    test "renders site details", %{
      account: account,
      actor: actor,
      identity: identity,
      site: site,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      table =
        lv
        |> element("#site")
        |> render()
        |> vertical_table_to_map()

      assert table["name"] =~ site.name
      assert table["created"] =~ actor.name
    end

    test "renders online gateways table", %{
      account: account,
      identity: identity,
      site: site,
      gateway: gateway,
      conn: conn
    } do
      site_token = Fixtures.Sites.create_token(site: gateway.site, account: account)
      :ok = Domain.Presence.Gateways.connect(gateway, site_token.id)
      Fixtures.Gateways.create_gateway(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      rows =
        lv
        |> element("#gateways")
        |> render()
        |> table_to_map()

      assert length(rows) == 1

      rows
      |> with_table_row("instance", gateway.name, fn row ->
        assert gateway.last_seen_remote_ip
        assert row["remote ip"] =~ to_string(gateway.last_seen_remote_ip)
        assert row["status"] =~ "Online"
      end)
    end

    test "updates online gateways table", %{
      account: account,
      site: site,
      gateway: gateway,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      :ok = Domain.Presence.Gateways.Site.subscribe(site.id)
      site_token = Fixtures.Sites.create_token(site: gateway.site, account: account)
      :ok = Domain.Presence.Gateways.connect(gateway, site_token.id)
      assert_receive %Phoenix.Socket.Broadcast{topic: "presences:sites:#{gateway.site.id}"}

      wait_for(fn ->
        lv
        |> element("#gateways")
        |> render()
        |> table_to_map()
        |> with_table_row("instance", gateway.name, fn row ->
          assert row["status"] =~ "Online"
        end)
      end)
    end

    test "allows revoking all tokens", %{
      account: account,
      site: site,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      assert lv
             |> element("button[type=submit]", "Revoke All")
             |> render_click() =~ "1 token(s) were revoked."

      refute Repo.get_by(Domain.Token, site_id: site.id)
    end

    test "renders resources table", %{
      account: account,
      identity: identity,
      site: site,
      conn: conn
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{site_id: site.id}]
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      resource_rows =
        lv
        |> element("#resources")
        |> render()
        |> table_to_map()

      Enum.each(resource_rows, fn row ->
        assert row["name"] =~ resource.name
        assert row["address"] =~ resource.address
        assert row["authorized groups"] == "None. Create a Policy to grant access."
      end)
    end

    test "renders authorized groups peek", %{
      account: account,
      identity: identity,
      site: site,
      conn: conn
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{site_id: site.id}]
        )

      policies =
        [
          Fixtures.Policies.create_policy(
            account: account,
            resource: resource
          ),
          Fixtures.Policies.create_policy(
            account: account,
            resource: resource
          ),
          Fixtures.Policies.create_policy(
            account: account,
            resource: resource
          )
        ]
        |> Repo.preload(:actor_group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      resource_rows =
        lv
        |> element("#resources")
        |> render()
        |> table_to_map()

      Enum.each(resource_rows, fn row ->
        for policy <- policies do
          assert row["authorized groups"] =~ policy.actor_group.name
        end
      end)

      Fixtures.Policies.create_policy(
        account: account,
        resource: resource
      )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      resource_rows =
        lv
        |> element("#resources")
        |> render()
        |> table_to_map()

      Enum.each(resource_rows, fn row ->
        assert row["authorized groups"] =~ "and 1 more"
      end)
    end

    test "allows deleting sites", %{
      account: account,
      site: site,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      lv
      |> element("button[type=submit]", "Delete")
      |> render_click()

      assert_redirected(lv, ~p"/#{account}/sites")

      refute Repo.get(Domain.Site, site.id)
    end
  end

  describe "for internet sites" do
    setup %{account: account, subject: subject} do
      site = Fixtures.Sites.create_internet_site(account)
      gateway = Fixtures.Gateways.create_gateway(account: account, site: site)
      gateway = Repo.preload(gateway, :site)
      resource = Fixtures.Resources.create_internet_resource(account, site)

      %{
        site: site,
        gateway: gateway,
        resource: resource,
        subject: subject
      }
    end

    test "does not allow editing", %{
      account: account,
      site: site,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      refute has_element?(lv, "a", "Edit Site")
    end

    test "renders online gateways table", %{
      account: account,
      identity: identity,
      site: site,
      gateway: gateway,
      conn: conn
    } do
      site_token = Fixtures.Sites.create_token(site: gateway.site, account: account)
      :ok = Domain.Presence.Gateways.connect(gateway, gateway_token.id)
      Fixtures.Gateways.create_gateway(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      rows =
        lv
        |> element("#gateways")
        |> render()
        |> table_to_map()

      assert length(rows) == 1

      rows
      |> with_table_row("instance", gateway.name, fn row ->
        assert gateway.last_seen_remote_ip
        assert row["remote ip"] =~ to_string(gateway.last_seen_remote_ip)
        assert row["status"] =~ "Online"
      end)
    end

    test "updates online gateways table", %{
      account: account,
      site: site,
      gateway: gateway,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      :ok = Domain.Presence.Gateways.Site.subscribe(site.id)
      site_token = Fixtures.Sites.create_token(site: gateway.site, account: account)
      :ok = Domain.Presence.Gateways.connect(gateway, gateway_token.id)
      assert_receive %Phoenix.Socket.Broadcast{topic: "presences:sites:#{gateway.site.id}"}

      wait_for(fn ->
        lv
        |> element("#gateways")
        |> render()
        |> table_to_map()
        |> with_table_row("instance", gateway.name, fn row ->
          assert row["status"] =~ "Online"
        end)
      end)
    end

    test "allows revoking all tokens", %{
      account: account,
      site: site,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      assert lv
             |> element("button[type=submit]", "Revoke All")
             |> render_click() =~ "1 token(s) were revoked."

      refute Repo.get_by(Domain.Token, site_id: site.id)
    end

    test "does not render resources table", %{
      account: account,
      identity: identity,
      site: site,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      refute has_element?(lv, "#resources")
    end

    test "renders policies table", %{
      account: account,
      identity: identity,
      site: site,
      resource: resource,
      conn: conn
    } do
      Fixtures.Policies.create_policy(
        account: account,
        resource: resource
      )

      Fixtures.Policies.create_policy(
        account: account,
        resource: resource
      )

      Fixtures.Policies.create_policy(
        account: account,
        resource: resource
      )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      rows =
        lv
        |> element("#policies")
        |> render()
        |> table_to_map()

      assert Enum.all?(rows, fn row ->
               assert row["group"]
               assert row["id"]
               assert row["status"] == "Active"
             end)
    end

    test "does not allow deleting the site", %{
      account: account,
      site: site,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{site}")

      refute has_element?(lv, "button[type=submit]", "Delete")
    end
  end
end
