defmodule Web.Live.Policies.NewTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    actor_group = Fixtures.Actors.create_group(account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    %{
      account: account,
      actor: actor,
      actor_group: actor_group,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    conn: conn
  } do
    path = ~p"/#{account}/policies/new"

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
      |> live(~p"/#{account}/policies/new")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Policies"
    assert breadcrumbs =~ "Add"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "policy[actor_group_id]",
             "policy[actor_group_id]_name",
             "policy[description]",
             "policy[resource_id]",
             "policy[resource_id]_name",
             "search_query-policy_actor_group_id",
             "search_query-policy_resource_id"
           ]
  end

  test "renders form with pre-set actor_group_id", %{
    account: account,
    identity: identity,
    actor_group: actor_group,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?actor_group_id=#{actor_group.id}")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "policy[actor_group_id]",
             "policy[actor_group_id]_name",
             "policy[description]",
             "policy[resource_id]",
             "policy[resource_id]_name",
             "search_query-policy_actor_group_id",
             "search_query-policy_resource_id"
           ]

    html = render(form)

    disabled_input = Floki.find(html, "input[name='policy[actor_group_id]_name']")
    assert Floki.attribute(disabled_input, "disabled") == ["disabled"]
    assert Floki.attribute(disabled_input, "value") == [actor_group.name]

    value_input = Floki.find(html, "input[name='policy[actor_group_id]']")
    assert Floki.attribute(value_input, "value") == [actor_group.id]
  end

  test "renders form with pre-set resource_id", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    resource = Fixtures.Resources.create_resource(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource.id}")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "policy[actor_group_id]",
             "policy[actor_group_id]_name",
             "policy[conditions][client_verified][operator]",
             "policy[conditions][client_verified][property]",
             "policy[conditions][client_verified][values][]",
             "policy[conditions][current_utc_datetime][operator]",
             "policy[conditions][current_utc_datetime][property]",
             "policy[conditions][current_utc_datetime][timezone]",
             "policy[conditions][current_utc_datetime][values][F]",
             "policy[conditions][current_utc_datetime][values][M]",
             "policy[conditions][current_utc_datetime][values][R]",
             "policy[conditions][current_utc_datetime][values][S]",
             "policy[conditions][current_utc_datetime][values][T]",
             "policy[conditions][current_utc_datetime][values][U]",
             "policy[conditions][current_utc_datetime][values][W]",
             "policy[conditions][provider_id][operator]",
             "policy[conditions][provider_id][property]",
             "policy[conditions][provider_id][values][]",
             "policy[conditions][remote_ip][operator]",
             "policy[conditions][remote_ip][property]",
             "policy[conditions][remote_ip][values][]",
             "policy[conditions][remote_ip_location_region][operator]",
             "policy[conditions][remote_ip_location_region][property]",
             "policy[conditions][remote_ip_location_region][values][]",
             "policy[description]",
             "policy[resource_id]",
             "policy[resource_id]_name",
             "search_query-policy_actor_group_id",
             "search_query-policy_resource_id"
           ]

    html = render(form)

    disabled_input = Floki.find(html, "input[name='policy[resource_id]_name']")
    assert Floki.attribute(disabled_input, "disabled") == ["disabled"]
    assert Floki.attribute(disabled_input, "value") == [resource.name]

    value_input = Floki.find(html, "input[name='policy[resource_id]']")
    assert Floki.attribute(value_input, "value") == [resource.id]
  end

  test "form changes depending on resource type", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    internet_gateway_group = Fixtures.Gateways.create_internet_group(account: account)

    resource =
      Fixtures.Resources.create_internet_resource(
        account: account,
        connections: [%{gateway_group_id: internet_gateway_group.id}]
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource.id}")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "policy[actor_group_id]",
             "policy[actor_group_id]_name",
             "policy[conditions][client_verified][operator]",
             "policy[conditions][client_verified][property]",
             "policy[conditions][client_verified][values][]",
             "policy[conditions][provider_id][operator]",
             "policy[conditions][provider_id][property]",
             "policy[conditions][provider_id][values][]",
             "policy[conditions][remote_ip][operator]",
             "policy[conditions][remote_ip][property]",
             "policy[conditions][remote_ip][values][]",
             "policy[conditions][remote_ip_location_region][operator]",
             "policy[conditions][remote_ip_location_region][property]",
             "policy[conditions][remote_ip_location_region][values][]",
             "policy[description]",
             "policy[resource_id]",
             "policy[resource_id]_name",
             "search_query-policy_actor_group_id",
             "search_query-policy_resource_id"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    attrs =
      %{}
      |> Map.put(:actor_group_id, group.id)
      |> Map.put(:resource_id, resource.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new")

    lv
    |> form("form", policy: attrs)
    |> validate_change(%{policy: %{description: String.duplicate("a", 1025)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "policy[description]" => ["should be at most 1024 character(s)"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    other_policy = Fixtures.Policies.create_policy(account: account)
    attrs = %{description: String.duplicate("a", 1025)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "policy[description]" => ["should be at most 1024 character(s)"],
             "policy[actor_group_id]_name" => ["can't be blank"],
             "policy[resource_id]_name" => ["can't be blank"]
           }

    attrs = %{
      description: "",
      actor_group_id: other_policy.actor_group_id,
      resource_id: other_policy.resource_id
    }

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "policy[base]" => ["Policy for the selected Group and Resource already exists"]
           }
  end

  test "creates a new policy on valid attrs and redirects to policies page", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    attrs = %{
      actor_group_id: group.id,
      resource_id: resource.id
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()

    assert Repo.get_by(Domain.Policies.Policy, attrs)

    flash = assert_redirect(lv, ~p"/#{account}/policies")
    assert flash["info"] == "Policy created successfully."
  end

  test "creates a new policy with conditions", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    attrs = %{
      actor_group_id: group.id,
      resource_id: resource.id,
      conditions: %{
        current_utc_datetime: %{
          property: "current_utc_datetime",
          operator: "is_in_day_of_week_time_ranges",
          timezone: "US/Pacific",
          values: %{
            M: "true",
            T: "",
            W: "true",
            R: "",
            F: "",
            S: "10:00:00-15:00:00",
            U: "23:00:00-23:59:59"
          }
        },
        provider_id: %{
          property: "provider_id",
          operator: "is_in",
          values: [identity.provider_id]
        },
        remote_ip: %{
          property: "remote_ip",
          operator: "is_not_in_cidr",
          values: ["0.0.0.0/0"]
        },
        remote_ip_location_region: %{
          property: "remote_ip_location_region",
          operator: "is_in",
          values: ["US"]
        }
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource}")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Domain.Policies.Policy, actor_group_id: group.id)
    assert policy.resource_id == resource.id

    assert policy.conditions == [
             %Domain.Policies.Condition{
               property: :current_utc_datetime,
               operator: :is_in_day_of_week_time_ranges,
               values: [
                 "M/true/US/Pacific",
                 "T//US/Pacific",
                 "W/true/US/Pacific",
                 "R//US/Pacific",
                 "F//US/Pacific",
                 "S/10:00:00-15:00:00/US/Pacific",
                 "U/23:00:00-23:59:59/US/Pacific"
               ]
             },
             %Domain.Policies.Condition{
               property: :provider_id,
               operator: :is_in,
               values: [identity.provider_id]
             },
             %Domain.Policies.Condition{
               property: :remote_ip,
               operator: :is_not_in_cidr,
               values: ["0.0.0.0/0"]
             },
             %Domain.Policies.Condition{
               property: :remote_ip_location_region,
               operator: :is_in,
               values: ["US"]
             }
           ]

    assert assert_redirect(lv, ~p"/#{account}/resources/#{resource}")
  end

  test "creates a new policy on valid attrs and pre-set resource_id", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    attrs =
      %{actor_group_id: group.id}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource}")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Domain.Policies.Policy, attrs)
    assert policy.resource_id == resource.id

    assert assert_redirect(lv, ~p"/#{account}/resources/#{resource}")
  end

  test "removes conditions in the backend when policy_conditions is false", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account =
      Fixtures.Accounts.update_account(account,
        features: %{
          policy_conditions: false
        }
      )

    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    attrs = %{
      actor_group_id: group.id,
      conditions: %{
        current_utc_datetime: %{},
        provider_id: %{},
        remote_ip: %{},
        remote_ip_location_region: %{}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource}")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Domain.Policies.Policy, %{actor_group_id: group.id})
    assert policy.resource_id == resource.id
    assert policy.conditions == []

    assert_redirect(lv, ~p"/#{account}/resources/#{resource}")
  end

  test "redirects back to actor group when a new policy is created with pre-set actor_group_id",
       %{
         account: account,
         identity: identity,
         conn: conn
       } do
    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    Fixtures.Gateways.create_group(account: account)

    attrs = %{resource_id: resource.id}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?actor_group_id=#{group}")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Domain.Policies.Policy, attrs)
    assert policy.resource_id == resource.id

    assert assert_redirect(lv, ~p"/#{account}/groups/#{group}")
  end

  test "redirects back to site when a new policy is created with pre-set site_id", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    gateway_group = Fixtures.Gateways.create_group(account: account)

    attrs = %{actor_group_id: group.id, resource_id: resource.id}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?site_id=#{gateway_group.id}")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Domain.Policies.Policy, attrs)
    assert policy.resource_id == resource.id

    assert assert_redirect(lv, ~p"/#{account}/sites/#{gateway_group}?#resources")
  end
end
