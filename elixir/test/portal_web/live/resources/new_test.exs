defmodule PortalWeb.Live.Resources.NewTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.FeaturesFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    site = site_fixture(account: account)

    %{
      account: account,
      actor: actor,
      site: site
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    conn: conn
  } do
    path = ~p"/#{account}/resources/new"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
    assert breadcrumbs =~ "Add Resource"
  end

  test "renders form", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new?site_id=#{site}")

    form = form(lv, "form[phx-submit='submit']")

    expected_inputs =
      [
        "resource[address]",
        "resource[address_description]",
        "resource[filters][icmp][enabled]",
        "resource[filters][icmp][protocol]",
        "resource[filters][tcp][enabled]",
        "resource[filters][tcp][ports]",
        "resource[filters][tcp][protocol]",
        "resource[filters][udp][enabled]",
        "resource[filters][udp][ports]",
        "resource[filters][udp][protocol]",
        "resource[name]",
        "resource[type]"
      ]
      |> Enum.sort()

    assert find_inputs(form) == expected_inputs
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new?site_id=#{site}")

    lv |> form("form[phx-submit='submit']") |> render_change(resource: %{type: :dns})

    errors =
      lv
      |> form("form[phx-submit='submit']",
        resource: %{name: String.duplicate("a", 256), address: "example.com"}
      )
      |> render_submit()
      |> form_validation_errors()

    assert "should be at most 255 character(s)" in errors["resource[name]"]
  end

  test "creates a resource on valid attrs", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    attrs = %{
      name: "foobar.com",
      address: "foobar.com",
      address_description: "http://foobar.com:3000/"
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new?site_id=#{site}")

    lv |> form("form[phx-submit='submit']") |> render_change(resource: %{type: :dns})
    lv |> form("form[phx-submit='submit']", resource: attrs) |> render_submit()

    resource = Repo.get_by(Portal.Resource, %{name: attrs.name, address: attrs.address})
    assert resource.site_id == site.id

    flash =
      assert_redirect(lv, ~p"/#{account}/policies/new?resource_id=#{resource}&site_id=#{site}")

    assert flash["success"] =~ "Resource #{resource.name} created successfully"
  end

  test "creates a resource with site selected from the form", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    attrs = %{
      name: "example.com",
      address: "example.com",
      type: "dns",
      site_id: site.id
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    lv |> form("form[phx-submit='submit']") |> render_change(resource: %{type: :dns})
    lv |> form("form[phx-submit='submit']", resource: attrs) |> render_submit()

    resource = Repo.get_by(Portal.Resource, %{name: attrs.name, address: attrs.address})

    flash = assert_redirect(lv, ~p"/#{account}/policies/new?resource_id=#{resource}")
    assert flash["success"] =~ "Resource #{resource.name} created successfully"
  end

  test "renders changeset errors on change", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new?site_id=#{site}")

    lv |> form("form[phx-submit='submit']") |> render_change(resource: %{type: :dns})

    html =
      lv
      |> form("form[phx-submit='submit']",
        resource: %{name: String.duplicate("a", 256), address: "example.com", type: "dns"}
      )
      |> render_submit()

    assert html =~ "should be at most 255 character(s)"
  end

  # Device pool tests

  test "does not show Device Pool type when client_to_client feature is disabled", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    refute html =~ "Device Pool"
  end

  test "shows Device Pool type when client_to_client feature is enabled", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    update_account(account, features: %{client_to_client: true})

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    assert html =~ "Device Pool"
  end

  test "selecting device pool type shows client picker and hides address/site fields", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    update_account(account, features: %{client_to_client: true})

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    html =
      lv
      |> form("form[phx-submit='submit']")
      |> render_change(resource: %{type: :static_device_pool})

    assert html =~ "Search clients to add"
    refute html =~ ~r/label.*Address/
    refute html =~ "site_id"
  end

  test "can search for clients in device pool picker", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    update_account(account, features: %{client_to_client: true})
    _client = client_fixture(account: account, name: "MyLaptop")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form[phx-submit='submit']")
    |> render_change(resource: %{type: :static_device_pool})

    html =
      lv
      |> element("input[name='client_search']")
      |> render_change(%{"client_search" => "MyLaptop"})

    assert html =~ "MyLaptop"
  end

  test "can search for clients in device pool picker by actor name", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    update_account(account, features: %{client_to_client: true})

    client_actor =
      actor_fixture(account: account, name: "Taylor Device User", email: "taylor@example.com")

    _client = client_fixture(account: account, actor: client_actor, name: "Laptop-01")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form[phx-submit='submit']")
    |> render_change(resource: %{type: :static_device_pool})

    html =
      lv
      |> element("input[name='client_search']")
      |> render_change(%{"client_search" => "Taylor Device User"})

    assert html =~ "Laptop-01"
  end

  test "can add a client to the device pool", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    update_account(account, features: %{client_to_client: true})
    client = client_fixture(account: account, name: "MyLaptop")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form[phx-submit='submit']")
    |> render_change(resource: %{type: :static_device_pool})

    lv
    |> element("input[name='client_search']")
    |> render_change(%{"client_search" => "MyLaptop"})

    html =
      lv
      |> element("button[phx-click='add_client'][phx-value-client_id='#{client.id}']")
      |> render_click()

    # Client appears in selected list
    assert html =~ "MyLaptop"
    # Search dropdown is dismissed
    refute html =~ "phx-click=\"add_client\""
  end

  test "creates a device pool resource with selected clients", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})
    client = client_fixture(account: account, name: "TestDevice")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form[phx-submit='submit']")
    |> render_change(resource: %{type: :static_device_pool})

    lv
    |> element("input[name='client_search']")
    |> render_change(%{"client_search" => "TestDevice"})

    lv
    |> element("button[phx-click='add_client'][phx-value-client_id='#{client.id}']")
    |> render_click()

    lv
    |> form("form[phx-submit='submit']",
      resource: %{name: "My Device Pool", type: "static_device_pool"}
    )
    |> render_submit()

    resource = Repo.get_by(Portal.Resource, %{name: "My Device Pool", type: :static_device_pool})
    assert resource

    flash = assert_redirect(lv, ~p"/#{account}/policies/new?resource_id=#{resource}")
    assert flash["success"] =~ "Resource My Device Pool created successfully"

    member =
      Repo.get_by(Portal.StaticDevicePoolMember, %{resource_id: resource.id, device_id: client.id})

    assert member
  end

  test "device pool resource does not require site or address", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/new")

    html =
      lv
      |> form("form[phx-submit='submit']")
      |> render_change(resource: %{type: :static_device_pool})

    # Site and address inputs are not shown for device pool type
    refute html =~ ~r/name="resource\[site_id\]"/
    refute html =~ ~r/name="resource\[address\]"/
  end
end
