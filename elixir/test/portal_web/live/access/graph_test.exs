defmodule PortalWeb.Access.GraphTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures

  setup %{conn: conn} do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    site = site_fixture(account: account, name: "Production")
    gateway = gateway_fixture(account: account, site: site, name: "gw-prod-1")
    group = group_fixture(account: account, name: "Engineering")
    resource = resource_fixture(account: account, site: site, name: "GitLab")
    policy_fixture(account: account, group: group, resource: resource)
    subject = subject_fixture(account: account, actor: actor)

    %{
      conn: authorize_conn_with_provider(conn, actor, %{id: subject.credential.auth_provider_id}),
      account: account,
      subject: subject,
      site: site,
      gateway: gateway,
      group: group,
      resource: resource
    }
  end

  test "redirects to sign in when not authenticated", %{account: account} do
    path = ~p"/#{account}/access"
    assert {:error, {:redirect, %{to: to}}} = live(build_conn(), path)
    assert to =~ "sign_in"
  end

  test "draws groups, resources, sites and devices with edges", %{
    conn: conn,
    account: account,
    site: site,
    gateway: gateway,
    group: group,
    resource: resource
  } do
    {:ok, lv, _html} = live(conn, ~p"/#{account}/access")

    for id <- ["group:#{group.id}", "resource:#{resource.id}", "site:#{site.id}", "device:#{gateway.id}"] do
      assert has_element?(lv, "#access-graph g[data-node='#{id}']")
    end

    assert has_element?(lv, "#access-graph path[data-from='group:#{group.id}'][data-to='resource:#{resource.id}']")
    assert has_element?(lv, "#access-graph path[data-from='resource:#{resource.id}'][data-to='site:#{site.id}']")
    assert has_element?(lv, "#access-graph path[data-from='site:#{site.id}'][data-to='device:#{gateway.id}']")
    assert has_element?(lv, "#access-graph g[data-node='device:#{gateway.id}'] circle.stroke-attn")
  end

  test "pins a node and links to it", %{conn: conn, account: account, group: group, resource: resource} do
    {:ok, lv, _html} = live(conn, ~p"/#{account}/access")

    assert render(lv) =~ "Nothing is pinned"

    lv |> element("#access-graph g[data-node='resource:#{resource.id}']") |> render_click()

    assert has_element?(lv, "#access-graph[data-pinned='resource:#{resource.id}']")
    assert has_element?(lv, "#access-graph-strip a[href='/#{account.slug}/groups/#{group.id}']", "Engineering")
    assert has_element?(lv, "#access-graph-open[href='/#{account.slug}/resources/#{resource.id}']")

    lv |> element("#access-graph-strip button", "Clear") |> render_click()
    refute has_element?(lv, "#access-graph[data-pinned]")
  end

  test "search keeps the matching nodes and their paths", %{
    conn: conn,
    account: account,
    group: group,
    resource: resource
  } do
    other_group = group_fixture(account: account, name: "Finance")
    other = resource_fixture(account: account, name: "Ledger")
    policy_fixture(account: account, group: other_group, resource: other)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/access")
    assert has_element?(lv, "g[data-node='resource:#{other.id}']")

    lv |> form("#access-graph-search", %{search: "gitlab"}) |> render_change()

    assert has_element?(lv, "g[data-node='resource:#{resource.id}']")
    assert has_element?(lv, "g[data-node='group:#{group.id}']")
    refute has_element?(lv, "g[data-node='resource:#{other.id}']")
    refute has_element?(lv, "g[data-node='group:#{other_group.id}']")

    lv |> form("#access-graph-search", %{search: "nothing like this"}) |> render_change()
    assert has_element?(lv, "#access-graph-empty")
  end

  test "shows direct access as a people node, not the group name", %{
    conn: conn,
    account: account,
    subject: subject,
    resource: resource
  } do
    alice = actor_fixture(account: account, name: "Alice")
    bob = actor_fixture(account: account, name: "Bob")
    {:ok, direct} = PortalWeb.DirectAccess.grant(resource, [alice.id, bob.id], subject)

    {:ok, lv, html} = live(conn, ~p"/#{account}/access")

    assert has_element?(lv, "g[data-node='people:#{direct.id}']", "2 people")
    assert has_element?(lv, "path[data-from='people:#{direct.id}'][data-to='resource:#{resource.id}']")
    refute html =~ direct.name
  end

  test "device pools skip the site column with dashed lines", %{conn: conn, account: account, group: group} do
    client = client_fixture(account: account, name: "build-box")
    pool = device_pool_resource_fixture(account: account, name: "Build boxes", devices: [client])
    policy_fixture(account: account, group: group, resource: pool)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/access")

    assert has_element?(
             lv,
             "path[data-from='resource:#{pool.id}'][data-to='device:#{client.id}'][stroke-dasharray]"
           )
  end

  test "caps very large maps with a note", %{conn: conn, account: account, site: site} do
    now = DateTime.utc_now()

    rows =
      for i <- 1..2_501 do
        %{
          id: Ecto.UUID.generate(),
          account_id: account.id,
          site_id: site.id,
          name: "Bulk #{i}",
          type: :ip,
          address: "10.#{div(i, 256)}.#{rem(i, 256)}.1",
          filters: [],
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Portal.Resource, rows)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/access")

    assert has_element?(lv, "#access-graph-cap", "Showing 2500 of 2502 resources.")

    # A column this long wraps into sub-columns so the map keeps a usable shape.
    xs =
      lv
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("g[data-node^='resource:'] rect")
      |> Floki.attribute("x")
      |> Enum.uniq()

    assert length(xs) > 1
  end
end
