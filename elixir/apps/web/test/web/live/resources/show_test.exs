defmodule Web.Live.Resources.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    site = Fixtures.Sites.create_site(account: account, subject: subject)
    gateway = Fixtures.Gateways.create_gateway(account: account, site: site)
    gateway = Repo.preload(gateway, :site)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        subject: subject,
        ip_stack: :ipv4_only,
        site_id: site.id
      )

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      site: site,
      gateway: gateway,
      resource: resource
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    resource: resource,
    conn: conn
  } do
    path = ~p"/#{account}/resources/#{resource}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders internet resource without action buttons", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    site = Fixtures.Sites.create_internet_site(account: account)

    resource =
      Fixtures.Resources.create_internet_resource(
        account: account,
        site_id: site.id
      )

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert active_buttons(html) == []
  end

  test "raises NotFoundError for deleted resource", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    resource = Fixtures.Resources.delete_resource(resource)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
    assert breadcrumbs =~ resource.name
  end

  test "allows editing resource", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert lv
           |> element("a", "Edit Resource")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/resources/#{resource}/edit", kind: :push}}}
  end

  test "renders resource details", %{
    account: account,
    actor: actor,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] =~ resource.name
    assert table["address"] =~ resource.address
    assert table["created"] =~ actor.name
    assert table["address description"] =~ resource.address_description
    assert table["ip stack"] =~ "IPv4 only"

    for filter <- resource.filters do
      assert String.downcase(table["traffic restriction"]) =~ Atom.to_string(filter.protocol)
    end
  end

  test "omits address_description row if null", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    resource = Fixtures.Resources.create_resource(account: account, address_description: nil)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["address description"] == ""
  end

  test "renders link for address_descriptions that look like links", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    resource =
      Fixtures.Resources.create_resource(
        account: account,
        address_description: "http://example.com"
      )

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert html |> Floki.parse_fragment!() |> Floki.find("a[href='https://example.com']")
  end

  test "renders traffic filters on show page even when traffic filters disabled", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:traffic_filters, false)

    resource = Fixtures.Resources.create_resource(account: account, filters: [])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["traffic restriction"] == "All traffic allowed"

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        filters: [%{protocol: :tcp, ports: []}]
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["traffic restriction"] == "TCP: All ports allowed"
  end

  test "renders policies table", %{
    account: account,
    identity: identity,
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
      |> live(~p"/#{account}/resources/#{resource}")

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

  test "renders sites row", %{
    account: account,
    identity: identity,
    site: site,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["connected sites"] =~ site.name
  end

  test "renders logs table", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    policy_authorization =
      Fixtures.PolicyAuthorizations.create_policy_authorization(
        account: account,
        resource: resource
      )

    policy_authorization =
      Repo.preload(policy_authorization,
        client: [:actor],
        gateway: [:site],
        policy: [:group, :resource]
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    [row] =
      lv
      |> element("#policy_authorizations")
      |> render()
      |> table_to_map()

    assert row["authorized"]
    assert row["policy"] =~ policy_authorization.policy.group.name
    assert row["policy"] =~ policy_authorization.policy.resource.name

    assert row["gateway"] ==
             "#{policy_authorization.gateway.site.name}-#{policy_authorization.gateway.name} #{policy_authorization.gateway.last_seen_remote_ip}"

    assert row["client, actor"] =~ policy_authorization.client.name
    assert row["client, actor"] =~ "owned by #{policy_authorization.client.actor.name}"
    assert row["client, actor"] =~ to_string(policy_authorization.client_remote_ip)
  end

  test "allows deleting resource", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert {:error, {:live_redirect, %{to: redirect_path, kind: :push}}} =
             lv
             |> element("button[type=submit]", "Delete Resource")
             |> render_click()

    assert redirect_path == ~p"/#{account}/resources"

    refute Repo.get(Domain.Resources.Resource, resource.id)
  end

  test "renders updated_by info when created by Identity", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    subject = Fixtures.Auth.create_subject(account: account, actor: actor)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        subject: subject,
        address_description: "http://example.com"
      )

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert html =~ "by #{actor.name}"
  end

  test "renders updated_by info when created by API client", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        subject: subject,
        address_description: "http://example.com"
      )

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert html =~ "by #{subject.actor.name}"
  end
end
