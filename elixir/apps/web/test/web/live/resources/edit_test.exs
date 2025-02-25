defmodule Web.Live.Resources.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    group = Fixtures.Gateways.create_group(account: account, subject: subject)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        subject: subject,
        connections: [%{gateway_group_id: group.id}]
      )

    %{
      account: account,
      actor: actor,
      identity: identity,
      group: group,
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
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders not found error when resource is deleted", %{
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
         ])
      |> Enum.sort()

    assert find_inputs(form) == expected_inputs
  end

  test "renders form without connections when site is set by query param", %{
    account: account,
    group: group,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit?site_id=#{group}")

    form = form(lv, "form")

    assert find_inputs(form) == [
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
               "resource[filters][tcp][ports]" => ["bad format"]
             }
    end)
    |> validate_change(%{resource: %{filters: %{tcp: %{ports: "8080-90"}}}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "resource[filters][tcp][ports]" => [
                 "lower value cannot be higher than upper value"
               ]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    attrs = %{name: String.duplicate("a", 500)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    assert lv
           |> form("form", resource: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "resource[name]" => ["should be at most 255 character(s)"]
           }
  end

  test "updates a resource on valid breaking change attrs", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    conn = authorize_conn(conn, identity)

    attrs = %{
      name: "foobar.com",
      filters: %{
        icmp: %{enabled: true},
        tcp: %{ports: "8080, 4443"},
        udp: %{ports: "4000 - 5000"}
      }
    }

    :ok = Domain.Resources.subscribe_to_events_for_account(account)

    {:ok, lv, _html} =
      conn
      |> live(~p"/#{account}/resources/#{resource}/edit")

    {:ok, _lv, html} =
      lv
      |> form("form", resource: attrs)
      |> render_submit()
      |> follow_redirect(conn, ~p"/#{account}/resources")

    assert_receive {:delete_resource, _resource_id}
    assert_receive {:create_resource, _resource_id}

    assert updated_resource = Repo.get_by(Domain.Resources.Resource, id: resource.id)
    assert updated_resource.name == attrs.name
    assert html =~ "Resource #{updated_resource.name} updated successfully"

    updated_filters =
      for filter <- updated_resource.filters, into: %{} do
        {filter.protocol, %{ports: Enum.join(filter.ports, ", ")}}
      end

    assert Map.keys(updated_filters) == Map.keys(attrs.filters)
    assert updated_filters.tcp == attrs.filters.tcp
    assert updated_filters.udp == attrs.filters.udp
  end

  test "redirects to a site when site_id query param is set", %{
    account: account,
    identity: identity,
    group: group,
    resource: resource,
    conn: conn
  } do
    conn = authorize_conn(conn, identity)

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
      |> live(~p"/#{account}/resources/#{resource}/edit?site_id=#{group}")

    {:ok, _lv, html} =
      lv
      |> form("form", resource: attrs)
      |> render_submit()
      |> follow_redirect(conn, ~p"/#{account}/sites/#{group}")

    assert html =~ "Resource #{attrs.name} updated successfully"
  end

  test "shows disabled traffic filter form when traffic filters disabled", %{
    account: account,
    group: group,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:traffic_filters, false)

    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit?site_id=#{group}")

    form = form(lv, "form")

    assert find_inputs(form) == [
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

    assert html =~ "UPGRADE TO UNLOCK"
  end

  test "updates a resource on valid attrs when traffic filters disabled", %{
    account: account,
    group: group,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:traffic_filters, false)
    resource = Ecto.Changeset.change(resource, filters: []) |> Repo.update!()

    conn = authorize_conn(conn, identity)

    attrs = %{
      name: "foobar.com"
    }

    {:ok, lv, _html} =
      conn
      |> live(~p"/#{account}/resources/#{resource}/edit?site_id=#{group}")

    {:ok, _lv, html} =
      lv
      |> form("form", resource: attrs)
      |> render_submit()
      |> follow_redirect(conn, ~p"/#{account}/sites/#{group}")

    assert saved_resource = Repo.get_by(Domain.Resources.Resource, id: resource.id)
    assert saved_resource.name == attrs.name
    assert html =~ "Resource #{saved_resource.name} updated successfully."

    assert saved_resource.filters == []
  end

  test "maintains selection of site when multi-site is false", %{
    account: account,
    group: _group,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:multi_site_resources, false)
    group2 = Fixtures.Gateways.create_group(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    lv
    |> form("form")
    |> render_change(%{"resource[connections][0][gateway_group_id]" => group2.id})

    assert has_element?(
             lv,
             "select[name='resource[connections][0][gateway_group_id]'] option[value='#{group2.id}'][selected]"
           )
  end

  test "maintains selection of sites when multi-site is true", %{
    account: account,
    group: group,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    group2 = Fixtures.Gateways.create_group(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    lv
    |> form("form")
    |> render_change(%{
      "resource[connections][#{group.id}][enabled]" => false,
      "resource[connections][#{group2.id}][enabled]" => true
    })

    refute has_element?(lv, "input[name='resource[connections][#{group.id}][enabled]'][checked]")
    assert has_element?(lv, "input[name='resource[connections][#{group2.id}][enabled]'][checked]")
  end

  test "disables traffic filters form fields when traffic filters disabled", %{
    account: account,
    group: group,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:traffic_filters, false)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit?site_id=#{group}")

    assert has_element?(lv, "input[name='resource[filters][icmp][enabled]'][disabled]")
    assert has_element?(lv, "input[name='resource[filters][icmp][enabled]'][disabled]")
    assert has_element?(lv, "input[name='resource[filters][tcp][enabled]'][disabled]")
    assert has_element?(lv, "input[name='resource[filters][tcp][ports]'][disabled]")
    assert has_element?(lv, "input[name='resource[filters][udp][enabled]'][disabled]")
    assert has_element?(lv, "input[name='resource[filters][udp][ports]'][disabled]")
    assert saved_resource = Repo.get_by(Domain.Resources.Resource, id: resource.id)
    assert saved_resource.name == resource.name
    assert saved_resource.filters == resource.filters
  end

  test "redirects to resources page when resource type is edited", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    attrs = %{
      "resource[type]" => "ip",
      "resource[address]" => "1.2.3.4"
    }

    form = form(lv, "form")

    form
    |> render_change(attrs)

    form
    |> render_submit()

    assert_redirect(lv, ~p"/#{account}/resources")
  end

  test "redirects to resources page when resource address is edited", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}/edit")

    attrs = %{
      "resource[address]" => "foo.bar.com"
    }

    form = form(lv, "form")

    form
    |> render_change(attrs)

    form
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/resources")
  end
end
