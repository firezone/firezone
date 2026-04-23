defmodule PortalWeb.Live.Resources.ShowTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.FeaturesFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    site = site_fixture(account: account)

    resource =
      resource_fixture(
        account: account,
        site: site,
        type: :dns,
        address: "example.com",
        ip_stack: :ipv4_only
      )

    %{
      account: account,
      actor: actor,
      site: site,
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
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "raises NotFoundError for deleted resource", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    Repo.delete!(resource)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
    assert breadcrumbs =~ resource.name
  end

  test "allows editing resource", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
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
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] =~ resource.name
    assert table["address"] =~ resource.address
    assert table["ip stack"] =~ "IPv4 only"
  end

  test "renders sites row", %{
    account: account,
    actor: actor,
    site: site,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["site"] =~ site.name
  end

  test "renders policies table", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    policy_fixture(account: account, resource: resource)
    policy_fixture(account: account, resource: resource)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
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

  test "renders recent connection initiator and receiver device links", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    initiator = client_fixture(account: account, actor: actor)
    receiver_actor = actor_fixture(account: account)
    receiver = client_fixture(account: account, actor: receiver_actor)
    policy = policy_fixture(account: account, resource: resource)

    policy_authorization =
      policy_authorization_fixture(
        account: account,
        actor: actor,
        client: initiator,
        gateway: receiver,
        resource: resource,
        policy: policy
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")

    html =
      lv
      |> element("#policy_authorizations")
      |> render()

    [row] = table_to_map(html)

    assert row["initiator"] =~ initiator.name
    assert row["initiator"] =~ "owned by #{actor.name}"
    assert row["initiator"] =~ to_string(policy_authorization.client_remote_ip)
    assert row["receiver"] =~ receiver.name
    assert row["receiver"] =~ to_string(policy_authorization.gateway_remote_ip)
    assert html =~ ~s(href="/#{account.slug}/clients/#{initiator.id}")
    assert html =~ ~s(href="/#{account.slug}/clients/#{receiver.id}")
  end

  test "allows deleting resource", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")

    assert {:error, {:live_redirect, %{to: redirect_path, kind: :push}}} =
             lv
             |> element("button[type=submit]", "Delete Resource")
             |> render_click()

    assert redirect_path == ~p"/#{account}/resources"

    refute Repo.get_by(Portal.Resource, id: resource.id)
  end

  # Device pool tests

  test "renders device pool details with member list", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})
    client1 = client_fixture(account: account, name: "AlphaDevice")
    client2 = client_fixture(account: account, name: "BetaDevice")

    resource =
      static_device_pool_resource_fixture(
        account: account,
        name: "My Device Pool",
        clients: [client1, client2]
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")

    html =
      lv
      |> element("#resource")
      |> render()

    assert html =~ "AlphaDevice"
    assert html =~ "BetaDevice"
  end

  test "renders device pool details page without site or address rows", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})

    resource = static_device_pool_resource_fixture(account: account, name: "Pool")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] =~ "Pool"
    refute Map.has_key?(table, "address")
    refute Map.has_key?(table, "connected sites")
  end

  test "truncates device pool member list to 5 with 'and N more' link", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})

    clients =
      for i <- 1..7 do
        client_fixture(account: account, name: "Device#{i}")
      end

    resource =
      static_device_pool_resource_fixture(
        account: account,
        name: "Big Pool",
        clients: clients
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")

    html =
      lv
      |> element("#resource")
      |> render()

    # Shows 5 items max, then truncation message
    assert html =~ "and 2 more"
  end

  test "shows device pool member IPv4 address", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})
    client = client_fixture(account: account, name: "IPDevice")

    resource = static_device_pool_resource_fixture(account: account, clients: [client])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}")

    html =
      lv
      |> element("#resource")
      |> render()

    assert html =~ "IPDevice"
    # IPv4 address should be shown (client_fixture creates one by default)
    assert html =~ ~r/\d+\.\d+\.\d+\.\d+/
  end
end
