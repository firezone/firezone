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

  test "renders form when multi-site resources are disabled", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account =
      Fixtures.Accounts.update_account(account,
        features: %{
          traffic_filters: false,
          multi_site_resources: false
        }
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    form = form(lv, "form")

    connection_inputs = [
      "resource[connections][0][enabled]",
      "resource[connections][0][gateway_group_id]"
    ]

    expected_inputs =
      (connection_inputs ++
         [
           "resource[filters][icmp][enabled]",
           "resource[filters][icmp][protocol]",
           "resource[filters][tcp][enabled]",
           "resource[filters][tcp][protocol]",
           "resource[filters][tcp][ports]",
           "resource[filters][udp][enabled]",
           "resource[filters][udp][protocol]",
           "resource[filters][udp][ports]",
           "resource[address]",
           "resource[address_description]",
           "resource[name]",
           "resource[type]"
         ])
      |> Enum.sort()

    assert find_inputs(form) == expected_inputs
  end

  test "renders form when multi-site resources are enabled", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    account =
      Fixtures.Accounts.update_account(account,
        features: %{
          traffic_filters: true,
          multi_site_resources: true
        }
      )

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
           "resource[filters][icmp][enabled]",
           "resource[filters][icmp][protocol]",
           "resource[filters][tcp][enabled]",
           "resource[filters][tcp][protocol]",
           "resource[filters][tcp][ports]",
           "resource[filters][udp][enabled]",
           "resource[filters][udp][protocol]",
           "resource[filters][udp][ports]",
           "resource[name]",
           "resource[type]"
         ])
      |> Enum.sort()

    assert find_inputs(form) == expected_inputs
  end

  test "renders form when traffic filters are enabled", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account =
      Fixtures.Accounts.update_account(account,
        features: %{
          traffic_filters: false
        }
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    form = form(lv, "form")

    connection_inputs = [
      "resource[connections][0][enabled]",
      "resource[connections][0][gateway_group_id]"
    ]

    expected_inputs =
      (connection_inputs ++
         [
           "resource[filters][icmp][enabled]",
           "resource[filters][icmp][protocol]",
           "resource[filters][tcp][enabled]",
           "resource[filters][tcp][protocol]",
           "resource[filters][tcp][ports]",
           "resource[filters][udp][enabled]",
           "resource[filters][udp][protocol]",
           "resource[filters][udp][ports]",
           "resource[address]",
           "resource[address_description]",
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
    # Generate onchange to trigger visible elements, otherwise the form won't be valid
    |> render_change(
      resource: %{type: :dns, filters: %{tcp: %{enabled: true}, udp: %{enabled: true}}}
    )

    lv
    |> form("form", resource: attrs)
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
    # Generate onchange to trigger visible elements, otherwise the form won't be valid
    |> render_change(
      resource: %{type: :dns, filters: %{tcp: %{enabled: true}, udp: %{enabled: true}}}
    )

    assert lv
           |> form("form", resource: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "resource[name]" => ["should be at most 255 character(s)"],
             "connections" => ["can't be blank"]
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
      address_description: String.duplicate("a", 513),
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
    # Generate onchange to trigger visible elements, otherwise the form won't be valid
    |> render_change(
      resource: %{
        type: :dns,
        filters: %{tcp: %{enabled: true}, udp: %{enabled: true}}
      }
    )

    assert lv
           |> form("form", resource: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "resource[address]" => ["can't be blank"],
             "resource[address_description]" => ["should be at most 512 character(s)"]
           }
  end

  test "renders changeset errors for connections on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Resources.create_resource(account: account)

    attrs = %{
      name: "foo",
      address: "foobar.com",
      address_description: "http://foobar.com:3000/",
      connections: %{}
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form")
    # Generate onchange to trigger visible elements, otherwise the form won't be valid
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
        tcp: %{ports: "80, 443", enabled: true},
        udp: %{ports: "4000 - 5000", enabled: true}
      },
      connections: %{gateway_group.id => %{enabled: true}}
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form")
    # Generate onchange to trigger visible elements, otherwise the form won't be valid
    |> render_change(
      resource: %{
        type: :dns,
        filters: %{tcp: %{enabled: true}, udp: %{enabled: true}, icmp: %{enabled: true}}
      }
    )

    lv
    |> form("form", resource: attrs)
    |> render_submit()

    resource = Repo.get_by(Domain.Resources.Resource, %{name: attrs.name, address: attrs.address})

    flash = assert_redirect(lv, ~p"/#{account}/policies/new?resource_id=#{resource}")
    assert flash["info"] == "Resource #{resource.name} created successfully."
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
        tcp: %{ports: "80, 443", enabled: true},
        udp: %{ports: "4000 - 5000", enabled: true}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new?site_id=#{group}")

    lv
    |> form("form")
    # Generate onchange to trigger visible elements, otherwise the form won't be valid
    |> render_change(
      resource: %{
        type: :dns,
        filters: %{tcp: %{enabled: true}, udp: %{enabled: true}, icmp: %{enabled: true}}
      }
    )

    lv
    |> form("form", resource: attrs)
    |> render_submit()

    resource = Repo.get_by(Domain.Resources.Resource, %{name: attrs.name, address: attrs.address})

    flash =
      assert_redirect(lv, ~p"/#{account}/policies/new?resource_id=#{resource}&site_id=#{group}")

    assert flash["info"] == "Resource #{resource.name} created successfully."
  end

  test "shows disabled traffic filter form when traffic filters disabled", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:traffic_filters, false)

    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new?site_id=#{group}")

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

  test "sets ip_stack when resource type is dns", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    attrs = %{
      name: "foobar.com",
      address: "foobar.com",
      ip_stack: "ipv4_only"
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
    assert resource.ip_stack == :ipv4_only
  end

  test "renders ip stack recommendation", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    attrs = %{
      name: "Mongo DB",
      address: "**.mongodb.net",
      ip_stack: :ipv6_only,
      type: :dns
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new?site_id=#{group}")

    html =
      lv
      |> form("form")
      |> render_change(resource: attrs)

    assert html =~ "Recommended for this Resource"
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
    # Generate onchange to trigger visible elements, otherwise the form won't be valid
    |> render_change(resource: %{type: :dns})

    lv
    |> form("form", resource: attrs)
    |> render_submit()

    resource = Repo.get_by(Domain.Resources.Resource, %{name: attrs.name, address: attrs.address})
    assert %{connections: [connection]} = Repo.preload(resource, :connections)
    assert connection.gateway_group_id == group.id

    assert assert_redirect(
             lv,
             ~p"/#{account}/policies/new?resource_id=#{resource}&site_id=#{group}"
           )
  end

  test "prevents saving resource if traffic filters set when traffic filters disabled", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:traffic_filters, false)

    attrs = %{
      name: "foobar.com",
      filters: %{
        icmp: %{enabled: true},
        tcp: %{ports: "8080, 4443", enabled: true},
        udp: %{ports: "4000 - 5000", enabled: true}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new?site_id=#{group}")

    # ** (ArgumentError) could not find non-disabled input, select or textarea with name "resource[filters][tcp][ports]" within:
    assert_raise ArgumentError, fn ->
      lv
      |> form("form", resource: attrs)
      |> render_submit()
    end

    assert Repo.all(Domain.Resources.Resource) == []
  end

  test "maintains selection of site when multi-site is false", %{
    account: account,
    group: _group,
    identity: identity,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:multi_site_resources, false)
    group2 = Fixtures.Gateways.create_group(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

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
    identity: identity,
    conn: conn
  } do
    group2 = Fixtures.Gateways.create_group(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/new")

    lv
    |> form("form")
    |> render_change(%{
      "resource[connections][#{group.id}][enabled]" => false,
      "resource[connections][#{group2.id}][enabled]" => true
    })

    refute has_element?(lv, "input[name='resource[connections][#{group.id}][enabled]'][checked]")
    assert has_element?(lv, "input[name='resource[connections][#{group2.id}][enabled]'][checked]")
  end
end
