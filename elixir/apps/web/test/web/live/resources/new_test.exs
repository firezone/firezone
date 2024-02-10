defmodule Web.Live.Resources.NewTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    group = Fixtures.Gateways.create_group(account: account, subject: subject)

    %{
      account: account,
      actor: actor,
      identity: identity,
      group: group
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
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
    assert breadcrumbs =~ "Add Resource"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    form = form(lv, "form")

    connection_inputs = [
      "resource[connections][#{group.id}][enabled]",
      "resource[connections][#{group.id}][gateway_group_id]"
    ]

    expected_inputs =
      (connection_inputs ++
         [
           "resource[address]",
           "resource[address_description]",
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
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new?site_id=#{group}")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "resource[address]",
             "resource[address_description]",
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
             "resource[name]",
             "resource[type]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      name: "my website",
      address: "foobar.com",
      filters: %{
        tcp: %{ports: "80, 443", enabled: true},
        udp: %{ports: "100,102-105", enabled: true}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form")
    |> render_change(resource: %{type: :dns})

    lv
    |> form("form", resource: attrs)
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

  test "renders changeset errors for name on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      name: String.duplicate("a", 500),
      address: "foobar.com",
      filters: %{
        tcp: %{ports: "80, 443", enabled: true},
        udp: %{ports: "100", enabled: true}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form")
    |> render_change(resource: %{type: :dns})

    assert lv
           |> form("form", resource: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "resource[name]" => ["should be at most 255 character(s)"],
             "connections" => ["can't be blank"],
             "resource[address_description]" => ["can't be blank"]
           }
  end

  test "renders changeset errors for address on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    gateway_group = Fixtures.Gateways.create_group(account: account)

    attrs = %{
      name: "foobar.com",
      address: "",
      filters: %{
        tcp: %{ports: "80, 443", enabled: true},
        udp: %{ports: "100", enabled: true}
      },
      connections: %{gateway_group.id => %{enabled: true}}
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form")
    |> render_change(resource: %{type: :dns})

    assert lv
           |> form("form", resource: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "resource[address]" => ["can't be blank"],
             "resource[address_description]" => ["can't be blank"]
           }
  end

  test "renders changeset errors for connections on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    resource = Fixtures.Resources.create_resource(account: account)
    [connection | _] = resource.connections

    attrs = %{
      address: "foobar.com",
      address_description: "http://foobar.com:3000/",
      connections: %{connection.gateway_group_id => %{enabled: false}}
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form")
    |> render_change(resource: %{type: :dns})

    assert lv
           |> form("form", resource: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "connections" => ["can't be blank"]
           }
  end

  test "creates a resource on valid attrs and no site_id set", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    gateway_group = Fixtures.Gateways.create_group(account: account)

    attrs = %{
      name: "foobar.com",
      type: "dns",
      address: "foobar.com",
      address_description: "http://foobar.com:3000/",
      filters: %{
        icmp: %{enabled: true},
        tcp: %{ports: "80, 443"},
        udp: %{ports: "4000 - 5000"}
      },
      connections: %{gateway_group.id => %{enabled: true}}
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form")
    |> render_change(resource: %{type: :dns})

    lv
    |> form("form", resource: attrs)
    |> render_submit()

    resource = Repo.get_by(Domain.Resources.Resource, %{name: attrs.name, address: attrs.address})

    assert assert_redirect(lv, ~p"/#{account}/resources/#{resource}")
  end

  test "creates a resource on valid attrs and site_id set", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    attrs = %{
      name: "foobar.com",
      address: "foobar.com",
      address_description: "http://foobar.com:3000/",
      filters: %{
        icmp: %{enabled: true},
        tcp: %{ports: "80, 443"},
        udp: %{ports: "4000 - 5000"}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new?site_id=#{group}")

    lv
    |> form("form")
    |> render_change(resource: %{type: :dns})

    lv
    |> form("form", resource: attrs)
    |> render_submit()

    resource = Repo.get_by(Domain.Resources.Resource, %{name: attrs.name, address: attrs.address})

    assert assert_redirect(lv, ~p"/#{account}/resources/#{resource}?site_id=#{group.id}")
  end

  test "does not render traffic filter form", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:traffic_filters, false)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new?site_id=#{group}")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "resource[address]",
             "resource[address_description]",
             "resource[name]",
             "resource[type]"
           ]
  end

  test "creates a resource on valid attrs when traffic filter form disabled", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      name: "foobar.com",
      address: "foobar.com",
      address_description: "foobar.com"
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new?site_id=#{group}")

    lv
    |> form("form")
    |> render_change(resource: %{type: :dns})

    lv
    |> form("form", resource: attrs)
    |> render_submit()

    resource = Repo.get_by(Domain.Resources.Resource, %{name: attrs.name, address: attrs.address})
    assert %{connections: [connection]} = Repo.preload(resource, :connections)
    assert connection.gateway_group_id == group.id

    assert assert_redirect(lv, ~p"/#{account}/resources/#{resource}?site_id=#{group.id}")
  end
end
