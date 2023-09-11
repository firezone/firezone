defmodule Web.Live.Resources.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    # group = Fixtures.Gateways.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account, subject: subject)

    %{
      account: account,
      actor: actor,
      identity: identity,
      resource: resource
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    resource: resource,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/resources/#{resource}/edit") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when gateway is deleted", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    resource = Fixtures.Resources.delete_resource(resource)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
    assert breadcrumbs =~ resource.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    form = form(lv, "form")

    connection_inputs =
      for connection <- resource.connections do
        [
          "resource[connections][#{connection.gateway_group_id}][enabled]",
          "resource[connections][#{connection.gateway_group_id}][gateway_group_id]",
          "resource[connections][#{connection.gateway_group_id}][resource_id]"
        ]
      end
      |> List.flatten()

    expected_inputs =
      (connection_inputs ++
         [
           "resource[filters][all][enabled]",
           "resource[filters][all][protocol]",
           "resource[filters][icmp][enabled]",
           "resource[filters][icmp][protocol]",
           "resource[filters][tcp][enabled]",
           "resource[filters][tcp][ports]",
           "resource[filters][tcp][protocol]",
           "resource[filters][udp][enabled]",
           "resource[filters][udp][ports]",
           "resource[filters][udp][protocol]",
           "resource[name]"
         ])
      |> Enum.sort()

    assert find_inputs(form) == expected_inputs
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    attrs = %{
      name: "foobar.com",
      filters: %{
        tcp: %{ports: "80, 443"},
        udp: %{ports: "100"}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    lv
    |> form("form", resource: attrs)
    |> validate_change(%{resource: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "resource[name]" => ["should be at most 255 character(s)"]
             }
    end)
    |> validate_change(%{resource: %{filters: %{tcp: %{ports: "a"}}}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "resource[filters][tcp][ports]" => ["is invalid"]
             }
    end)
    |> validate_change(%{resource: %{filters: %{tcp: %{ports: "8080-90"}}}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "resource[filters][tcp][ports]" => ["is invalid"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    other_resource = Fixtures.Resources.create_resource(account: account)

    attrs = %{name: other_resource.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    assert lv
           |> form("form", resource: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "resource[name]" => ["has already been taken"]
           }

    connection_attrs =
      for connection <- resource.connections, into: %{} do
        {connection.gateway_group_id, %{enabled: false}}
      end

    attrs = %{connections: connection_attrs}

    assert lv
           |> form("form", resource: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "connections" => ["can't be blank"]
           }
  end

  test "updates a resource on valid attrs", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    attrs = %{
      name: "foobar.com",
      filters: %{
        icmp: %{enabled: true},
        tcp: %{ports: "8080, 4443"},
        udp: %{ports: "4000 - 5000"}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    assert lv
           |> form("form", resource: attrs)
           |> render_submit() ==
             {:error, {:live_redirect, %{to: ~p"/#{account}/resources/#{resource}", kind: :push}}}

    assert saved_resource = Repo.get_by(Domain.Resources.Resource, id: resource.id)
    assert saved_resource.name == attrs.name

    saved_filters =
      for filter <- saved_resource.filters, into: %{} do
        {filter.protocol, %{ports: Enum.join(filter.ports, ", ")}}
      end

    assert Map.keys(saved_filters) == Map.keys(attrs.filters)
    assert saved_filters.tcp == attrs.filters.tcp
    assert saved_filters.udp == attrs.filters.udp
  end

  test "disables all filters on a resource when 'Permit All' filter is selected", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    attrs = %{
      filters: %{
        all: %{enabled: true}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    assert lv
           |> form("form", resource: attrs)
           |> render_submit() ==
             {:error, {:live_redirect, %{to: ~p"/#{account}/resources/#{resource}", kind: :push}}}

    assert saved_resource = Repo.get_by(Domain.Resources.Resource, id: resource.id)

    saved_filters =
      for filter <- saved_resource.filters, into: %{} do
        {filter.protocol, %{ports: Enum.join(filter.ports, ", ")}}
      end

    assert saved_filters == %{all: %{ports: ""}}
  end
end
