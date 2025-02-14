defmodule Web.Live.Sites.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    group = Fixtures.Gateways.create_group(account: account, subject: subject)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)
    gateway = Repo.preload(gateway, :group)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      group: group,
      gateway: gateway
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    group: group,
    conn: conn
  } do
    path = ~p"/#{account}/sites/#{group}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders deleted gateway group without action buttons", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Gateways.delete_group(group)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}")

    assert html =~ "(deleted)"
    assert active_buttons(html) == []
  end

  test "renders breadcrumbs item", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
    assert breadcrumbs =~ group.name
  end

  describe "for non-managed sites" do
    test "allows editing gateway groups", %{
      account: account,
      group: group,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      assert lv
             |> element("a", "Edit Site")
             |> render_click() ==
               {:error, {:live_redirect, %{to: ~p"/#{account}/sites/#{group}/edit", kind: :push}}}
    end

    test "renders group details", %{
      account: account,
      actor: actor,
      identity: identity,
      group: group,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      table =
        lv
        |> element("#group")
        |> render()
        |> vertical_table_to_map()

      assert table["name"] =~ group.name
      assert table["created"] =~ actor.name
    end

    test "renders group details when group created by API", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(type: :api_client, account: account)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor)
      group = Fixtures.Gateways.create_group(account: account, subject: subject)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      table =
        lv
        |> element("#group")
        |> render()
        |> vertical_table_to_map()

      assert table["name"] =~ group.name
      assert table["created"] =~ actor.name
    end

    test "renders online gateways table", %{
      account: account,
      identity: identity,
      group: group,
      gateway: gateway,
      conn: conn
    } do
      :ok = Domain.Gateways.connect_gateway(gateway)
      Fixtures.Gateways.create_gateway(account: account, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

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
      group: group,
      gateway: gateway,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      :ok = Domain.Gateways.subscribe_to_gateways_presence_in_group(group)
      :ok = Domain.Gateways.connect_gateway(gateway)
      assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _}

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
      group: group,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      assert lv
             |> element("button[type=submit]", "Revoke All")
             |> render_click() =~ "1 token(s) were revoked."

      assert Repo.get_by(Domain.Tokens.Token, gateway_group_id: group.id).deleted_at
    end

    test "renders resources table", %{
      account: account,
      identity: identity,
      group: group,
      conn: conn
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: group.id}]
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

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
      group: group,
      conn: conn
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: group.id}]
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
        |> live(~p"/#{account}/sites/#{group}")

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
        |> live(~p"/#{account}/sites/#{group}")

      resource_rows =
        lv
        |> element("#resources")
        |> render()
        |> table_to_map()

      Enum.each(resource_rows, fn row ->
        assert row["authorized groups"] =~ "and 1 more"
      end)
    end

    test "allows deleting gateway groups", %{
      account: account,
      group: group,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      lv
      |> element("button[type=submit]", "Delete")
      |> render_click()

      assert_redirected(lv, ~p"/#{account}/sites")

      assert Repo.get(Domain.Gateways.Group, group.id).deleted_at
    end
  end

  describe "for non-internet resources" do
    test "allows editing gateway groups", %{
      account: account,
      group: group,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      assert lv
             |> element("a", "Edit Site")
             |> render_click() ==
               {:error, {:live_redirect, %{to: ~p"/#{account}/sites/#{group}/edit", kind: :push}}}
    end

    test "renders group details", %{
      account: account,
      actor: actor,
      identity: identity,
      group: group,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      table =
        lv
        |> element("#group")
        |> render()
        |> vertical_table_to_map()

      assert table["name"] =~ group.name
      assert table["created"] =~ actor.name
    end

    test "renders online gateways table", %{
      account: account,
      identity: identity,
      group: group,
      gateway: gateway,
      conn: conn
    } do
      :ok = Domain.Gateways.connect_gateway(gateway)
      Fixtures.Gateways.create_gateway(account: account, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

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
      group: group,
      gateway: gateway,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      :ok = Domain.Gateways.subscribe_to_gateways_presence_in_group(group)
      :ok = Domain.Gateways.connect_gateway(gateway)
      assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _}

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
      group: group,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      assert lv
             |> element("button[type=submit]", "Revoke All")
             |> render_click() =~ "1 token(s) were revoked."

      assert Repo.get_by(Domain.Tokens.Token, gateway_group_id: group.id).deleted_at
    end

    test "renders resources table", %{
      account: account,
      identity: identity,
      group: group,
      conn: conn
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: group.id}]
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

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
      group: group,
      conn: conn
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: group.id}]
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
        |> live(~p"/#{account}/sites/#{group}")

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
        |> live(~p"/#{account}/sites/#{group}")

      resource_rows =
        lv
        |> element("#resources")
        |> render()
        |> table_to_map()

      Enum.each(resource_rows, fn row ->
        assert row["authorized groups"] =~ "and 1 more"
      end)
    end

    test "allows deleting gateway groups", %{
      account: account,
      group: group,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      lv
      |> element("button[type=submit]", "Delete")
      |> render_click()

      assert_redirected(lv, ~p"/#{account}/sites")

      assert Repo.get(Domain.Gateways.Group, group.id).deleted_at
    end
  end

  describe "for internet sites" do
    setup %{account: account} do
      {:ok, group} = Domain.Gateways.create_internet_group(account)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)
      gateway = Repo.preload(gateway, :group)

      {:ok, resource} = Domain.Resources.create_internet_resource(account, group)

      %{
        group: group,
        gateway: gateway,
        resource: resource
      }
    end

    test "does not allow to editing", %{
      account: account,
      group: group,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      refute has_element?(lv, "a", "Edit Site")
    end

    test "renders group details", %{
      account: account,
      identity: identity,
      group: group,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      table =
        lv
        |> element("#group")
        |> render()
        |> vertical_table_to_map()

      assert table["name"] =~ "Internet"
      assert table["created"] =~ "system"
    end

    test "renders online gateways table", %{
      account: account,
      identity: identity,
      group: group,
      gateway: gateway,
      conn: conn
    } do
      :ok = Domain.Gateways.connect_gateway(gateway)
      Fixtures.Gateways.create_gateway(account: account, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

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
      group: group,
      gateway: gateway,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      :ok = Domain.Gateways.subscribe_to_gateways_presence_in_group(group)
      :ok = Domain.Gateways.connect_gateway(gateway)
      assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _}

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
      group: group,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      assert lv
             |> element("button[type=submit]", "Revoke All")
             |> render_click() =~ "1 token(s) were revoked."

      assert Repo.get_by(Domain.Tokens.Token, gateway_group_id: group.id).deleted_at
    end

    test "does not render resources table", %{
      account: account,
      identity: identity,
      group: group,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      refute has_element?(lv, "#resources")
    end

    test "renders policies table", %{
      account: account,
      identity: identity,
      group: group,
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
        |> live(~p"/#{account}/sites/#{group}")

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

    test "renders logs table", %{
      account: account,
      identity: identity,
      group: group,
      resource: resource,
      conn: conn
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          resource: resource
        )

      flow =
        Repo.preload(flow, client: [:actor], gateway: [:group], policy: [:actor_group, :resource])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      [row] =
        lv
        |> element("#flows")
        |> render()
        |> table_to_map()

      assert row["authorized"]
      assert row["policy"] =~ flow.policy.actor_group.name
      assert row["policy"] =~ flow.policy.resource.name

      assert row["gateway"] ==
               "#{flow.gateway.group.name}-#{flow.gateway.name} #{flow.gateway.last_seen_remote_ip}"

      assert row["client, actor"] =~ flow.client.name
      assert row["client, actor"] =~ "owned by #{flow.client.actor.name}"
      assert row["client, actor"] =~ to_string(flow.client_remote_ip)
    end

    test "does not allow deleting the group", %{
      account: account,
      group: group,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/sites/#{group}")

      refute has_element?(lv, "button[type=submit]", "Delete")
    end
  end
end
