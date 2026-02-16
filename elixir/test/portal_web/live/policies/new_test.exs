defmodule PortalWeb.Live.Policies.NewTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.ResourceFixtures
  import Portal.PolicyFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    group = group_fixture(account: account)

    %{
      account: account,
      actor: actor,
      group: group
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
      |> live(~p"/#{account}/policies/new")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Policies"
    assert breadcrumbs =~ "Add"
  end

  test "renders form", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new")

    form = form(lv, "form[phx-submit=submit]")

    expected_inputs =
      Enum.sort([
        "policy[group_id]",
        "policy[group_id]_name",
        "policy[description]",
        "policy[resource_id]",
        "policy[resource_id]_name",
        "search_query-policy_group_id",
        "search_query-policy_resource_id"
      ])

    assert find_inputs(form) == expected_inputs
  end

  test "renders form with pre-set group_id", %{
    account: account,
    actor: actor,
    group: group,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new?group_id=#{group.id}")

    form = form(lv, "form[phx-submit=submit]")

    expected_inputs =
      Enum.sort([
        "policy[group_id]",
        "policy[group_id]_name",
        "policy[description]",
        "policy[resource_id]",
        "policy[resource_id]_name",
        "search_query-policy_group_id",
        "search_query-policy_resource_id"
      ])

    assert find_inputs(form) == expected_inputs

    html = render(form)

    disabled_input =
      html |> Floki.parse_fragment!() |> Floki.find("input[name='policy[group_id]_name']")

    # disabled="" is equivalent to disabled="disabled" in HTML
    assert Floki.attribute(disabled_input, "disabled") == [""]
    assert Floki.attribute(disabled_input, "value") == [group.name]

    value_input =
      html |> Floki.parse_fragment!() |> Floki.find("input[name='policy[group_id]']")

    assert Floki.attribute(value_input, "value") == [group.id]
  end

  test "renders form with pre-set resource_id", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    resource = resource_fixture(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource.id}")

    form = form(lv, "form[phx-submit=submit]")

    expected_inputs =
      Enum.sort([
        "policy[group_id]",
        "policy[group_id]_name",
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
        "policy[conditions][auth_provider_id][operator]",
        "policy[conditions][auth_provider_id][property]",
        "policy[conditions][auth_provider_id][values][]",
        "policy[conditions][remote_ip][operator]",
        "policy[conditions][remote_ip][property]",
        "policy[conditions][remote_ip][values][]",
        "policy[conditions][remote_ip_location_region][operator]",
        "policy[conditions][remote_ip_location_region][property]",
        "policy[conditions][remote_ip_location_region][values][]",
        "policy[description]",
        "policy[resource_id]",
        "policy[resource_id]_name",
        "search_query-policy_group_id",
        "search_query-policy_resource_id"
      ])

    assert find_inputs(form) == expected_inputs

    html = render(form)

    disabled_input =
      html |> Floki.parse_fragment!() |> Floki.find("input[name='policy[resource_id]_name']")

    # disabled="" is equivalent to disabled="disabled" in HTML
    assert Floki.attribute(disabled_input, "disabled") == [""]
    assert Floki.attribute(disabled_input, "value") == [resource.name]

    value_input =
      html |> Floki.parse_fragment!() |> Floki.find("input[name='policy[resource_id]']")

    assert Floki.attribute(value_input, "value") == [resource.id]
  end

  test "form changes depending on resource type", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    internet_site = internet_site_fixture(account: account)

    resource =
      internet_resource_fixture(
        account: account,
        site: internet_site
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource.id}")

    form = form(lv, "form[phx-submit=submit]")

    expected_inputs =
      Enum.sort([
        "policy[group_id]",
        "policy[group_id]_name",
        "policy[conditions][client_verified][operator]",
        "policy[conditions][client_verified][property]",
        "policy[conditions][client_verified][values][]",
        "policy[conditions][auth_provider_id][operator]",
        "policy[conditions][auth_provider_id][property]",
        "policy[conditions][auth_provider_id][values][]",
        "policy[conditions][remote_ip][operator]",
        "policy[conditions][remote_ip][property]",
        "policy[conditions][remote_ip][values][]",
        "policy[conditions][remote_ip_location_region][operator]",
        "policy[conditions][remote_ip_location_region][property]",
        "policy[conditions][remote_ip_location_region][values][]",
        "policy[description]",
        "policy[resource_id]",
        "policy[resource_id]_name",
        "search_query-policy_group_id",
        "search_query-policy_resource_id"
      ])

    assert find_inputs(form) == expected_inputs
  end

  test "renders changeset errors on input change", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    group = group_fixture(account: account)
    resource = resource_fixture(account: account)

    attrs =
      %{}
      |> Map.put(:group_id, group.id)
      |> Map.put(:resource_id, resource.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new")

    lv
    |> form("form[phx-submit=submit]", policy: attrs)
    |> validate_change(%{policy: %{description: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "policy[description]" => ["should be at most 255 character(s)"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    other_policy = policy_fixture(account: account)
    attrs = %{description: String.duplicate("a", 256)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new")

    errors =
      lv
      |> form("form[phx-submit=submit]", policy: attrs)
      |> render_submit()
      |> form_validation_errors()

    assert "should be at most 255 character(s)" in errors["policy[description]"]
    assert "can't be blank" in errors["policy[group_id]_name"]
    assert "can't be blank" in errors["policy[resource_id]_name"]

    attrs = %{
      description: "",
      group_id: other_policy.group_id,
      resource_id: other_policy.resource_id
    }

    assert lv
           |> form("form[phx-submit=submit]", policy: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "policy[base]" => ["Policy for the selected Group and Resource already exists"]
           }
  end

  test "creates a new policy on valid attrs and redirects to policies page", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    group = group_fixture(account: account)
    resource = resource_fixture(account: account)

    attrs = %{
      group_id: group.id,
      resource_id: resource.id
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new")

    assert lv
           |> form("form[phx-submit=submit]", policy: attrs)
           |> render_submit()

    assert Repo.get_by(Portal.Policy, attrs)

    flash = assert_redirect(lv, ~p"/#{account}/policies")
    assert flash["success"] == "Policy created successfully"
  end

  test "creates a new policy on valid attrs and pre-set resource_id", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    group = group_fixture(account: account)
    resource = resource_fixture(account: account)

    attrs =
      %{group_id: group.id}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource}")

    assert lv
           |> form("form[phx-submit=submit]", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Portal.Policy, attrs)
    assert policy.resource_id == resource.id

    assert assert_redirect(lv, ~p"/#{account}/resources/#{resource}")
  end

  test "removes conditions in the backend when policy_conditions is false", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    account =
      update_account(account,
        features: %{
          policy_conditions: false
        }
      )

    group = group_fixture(account: account)
    resource = resource_fixture(account: account)

    attrs = %{
      group_id: group.id,
      conditions: %{
        current_utc_datetime: %{},
        auth_provider_id: %{},
        remote_ip: %{},
        remote_ip_location_region: %{}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource}")

    assert lv
           |> form("form[phx-submit=submit]", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Portal.Policy, %{group_id: group.id})
    assert policy.resource_id == resource.id
    assert policy.conditions == []

    assert_redirect(lv, ~p"/#{account}/resources/#{resource}")
  end

  test "redirects back to actor group when a new policy is created with pre-set group_id",
       %{
         account: account,
         actor: actor,
         conn: conn
       } do
    group = group_fixture(account: account)
    resource = resource_fixture(account: account)

    site_fixture(account: account)

    attrs = %{resource_id: resource.id}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new?group_id=#{group}")

    assert lv
           |> form("form[phx-submit=submit]", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Portal.Policy, attrs)
    assert policy.resource_id == resource.id

    assert assert_redirect(lv, ~p"/#{account}/groups/#{group}")
  end

  test "redirects back to site when a new policy is created with pre-set site_id", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    group = group_fixture(account: account)
    resource = resource_fixture(account: account)

    site = site_fixture(account: account)

    attrs = %{group_id: group.id, resource_id: resource.id}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/new?site_id=#{site.id}")

    assert lv
           |> form("form[phx-submit=submit]", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Portal.Policy, attrs)
    assert policy.resource_id == resource.id

    assert assert_redirect(lv, ~p"/#{account}/sites/#{site}?#resources")
  end
end
