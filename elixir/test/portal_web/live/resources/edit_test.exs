defmodule PortalWeb.Live.Resources.EditTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.FeaturesFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    site = site_fixture(account: account)

    resource = resource_fixture(account: account, site: site)

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
    path = ~p"/#{account}/resources/#{resource}/edit"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "renders not found error when resource is deleted", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    Repo.delete!(resource)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}/edit")
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
      |> live(~p"/#{account}/resources/#{resource}/edit")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
    assert breadcrumbs =~ resource.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    form = form(lv, "form[phx-submit='submit']")
    inputs = find_inputs(form)

    assert "resource[name]" in inputs
    assert "resource[address]" in inputs
    assert "resource[type]" in inputs
    assert "resource[site_id]" in inputs
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    errors =
      lv
      |> form("form[phx-submit='submit']", resource: %{name: String.duplicate("a", 256)})
      |> render_submit()
      |> form_validation_errors()

    assert "should be at most 255 character(s)" in errors["resource[name]"]
  end

  test "updates a resource on valid attrs", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    authorized_conn = authorize_conn(conn, actor)

    attrs = %{
      name: "updated-resource.com",
      address: resource.address
    }

    {:ok, lv, _html} =
      authorized_conn
      |> live(~p"/#{account}/resources/#{resource}/edit")

    {:ok, _lv, html} =
      lv
      |> form("form[phx-submit='submit']", resource: attrs)
      |> render_submit()
      |> follow_redirect(authorized_conn, ~p"/#{account}/resources")

    assert updated_resource = Repo.get_by(Portal.Resource, id: resource.id)
    assert updated_resource.name == attrs.name
    assert html =~ "Resource #{updated_resource.name} updated successfully"
  end

  test "redirects to a site when site_id query param is set", %{
    account: account,
    actor: actor,
    site: site,
    resource: resource,
    conn: conn
  } do
    authorized_conn = authorize_conn(conn, actor)

    attrs = %{name: "updated-resource.com"}

    {:ok, lv, _html} =
      authorized_conn
      |> live(~p"/#{account}/resources/#{resource}/edit?site_id=#{site}")

    {:ok, _lv, html} =
      lv
      |> form("form[phx-submit='submit']", resource: attrs)
      |> render_submit()
      |> follow_redirect(authorized_conn, ~p"/#{account}/sites/#{site}")

    assert html =~ "Resource #{attrs.name} updated successfully"
  end

  # Device pool tests

  test "renders device pool edit form with client picker", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})
    client = client_fixture(account: account, name: "ExistingDevice")
    resource = static_device_pool_resource_fixture(account: account, clients: [client])

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    assert html =~ "Search clients to add"
    assert html =~ "ExistingDevice"
  end

  test "can add a client to an existing device pool", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})
    existing_client = client_fixture(account: account, name: "ExistingDevice")
    new_client = client_fixture(account: account, name: "NewDevice")
    resource = static_device_pool_resource_fixture(account: account, clients: [existing_client])

    authorized_conn = authorize_conn(conn, actor)

    {:ok, lv, _html} =
      authorized_conn
      |> live(~p"/#{account}/resources/#{resource}/edit")

    lv
    |> element("input[name='client_search']")
    |> render_change(%{"client_search" => "NewDevice"})

    lv
    |> element("button[phx-click='add_client'][phx-value-client_id='#{new_client.id}']")
    |> render_click()

    {:ok, _lv, html} =
      lv
      |> form("form[phx-submit='submit']",
        resource: %{name: resource.name, type: "static_device_pool"}
      )
      |> render_submit()
      |> follow_redirect(authorized_conn, ~p"/#{account}/resources")

    assert html =~ "Resource #{resource.name} updated successfully"

    assert Repo.get_by(Portal.StaticDevicePoolMember, %{
             resource_id: resource.id,
             device_id: new_client.id
           })

    assert Repo.get_by(Portal.StaticDevicePoolMember, %{
             resource_id: resource.id,
             device_id: existing_client.id
           })
  end

  test "can search for clients in device pool picker by actor email", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})
    existing_client = client_fixture(account: account, name: "ExistingDevice")

    client_actor =
      actor_fixture(account: account, name: "Jordan Device User", email: "jordan@example.com")

    _client = client_fixture(account: account, actor: client_actor, name: "Phone-01")
    resource = static_device_pool_resource_fixture(account: account, clients: [existing_client])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    html =
      lv
      |> element("input[name='client_search']")
      |> render_change(%{"client_search" => "jordan@example.com"})

    assert html =~ "Phone-01"
  end

  test "can remove a client from an existing device pool", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    enable_feature(:client_to_client)
    account = update_account(account, features: %{client_to_client: true})
    client_to_keep = client_fixture(account: account, name: "KeepMe")
    client_to_remove = client_fixture(account: account, name: "RemoveMe")

    resource =
      static_device_pool_resource_fixture(
        account: account,
        clients: [client_to_keep, client_to_remove]
      )

    authorized_conn = authorize_conn(conn, actor)

    {:ok, lv, _html} =
      authorized_conn
      |> live(~p"/#{account}/resources/#{resource}/edit")

    lv
    |> element("button[phx-click='remove_client'][phx-value-client_id='#{client_to_remove.id}']")
    |> render_click()

    lv
    |> form("form[phx-submit='submit']",
      resource: %{name: resource.name, type: "static_device_pool"}
    )
    |> render_submit()
    |> follow_redirect(authorized_conn, ~p"/#{account}/resources")

    assert Repo.get_by(Portal.StaticDevicePoolMember, %{
             resource_id: resource.id,
             device_id: client_to_keep.id
           })

    refute Repo.get_by(Portal.StaticDevicePoolMember, %{
             resource_id: resource.id,
             device_id: client_to_remove.id
           })
  end
end
