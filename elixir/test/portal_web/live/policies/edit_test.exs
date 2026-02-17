defmodule PortalWeb.Live.Policies.EditTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.ResourceFixtures
  import Portal.PolicyFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    resource = resource_fixture(account: account)

    policy =
      policy_fixture(
        account: account,
        resource: resource,
        description: "Test Policy"
      )

    policy = Repo.preload(policy, [:group, :resource])

    %{
      account: account,
      actor: actor,
      resource: resource,
      policy: policy
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    policy: policy,
    conn: conn
  } do
    path = ~p"/#{account}/policies/#{policy}/edit"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "raises NoResultsError when policy is deleted", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    Repo.delete!(policy)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Policies"
    assert breadcrumbs =~ policy.group.name
    assert breadcrumbs =~ policy.resource.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")

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
  end

  test "renders changeset errors on input change", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    attrs = valid_policy_attrs() |> Map.take([:description])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    lv
    |> form("form[phx-submit=submit]", policy: attrs)
    |> validate_change(%{policy: %{description: String.duplicate("a", 1025)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "policy[description]" => ["should be at most 1024 character(s)"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    attrs = %{"description" => String.duplicate("a", 1025)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    form =
      lv
      |> form("form[phx-submit=submit]", policy: attrs)

    html = render_submit(form)

    errors = form_validation_errors(html)
    assert "should be at most 1024 character(s)" in errors["policy[description]"]

    assert unchanged_policy = Repo.get_by(Portal.Policy, id: policy.id)
    assert unchanged_policy.description == policy.description
  end

  test "updates a policy on valid attrs", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    attrs = valid_policy_attrs() |> Map.take([:description])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    lv
    |> form("form[phx-submit=submit]", policy: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/policies/#{policy}")

    assert policy = Repo.get_by(Portal.Policy, id: policy.id)
    assert policy.description == attrs.description
  end

  test "updates a policy on valid breaking change attrs", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    new_resource = resource_fixture(account: account)
    attrs = %{resource_id: new_resource.id}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    lv
    |> form("form[phx-submit=submit]", policy: attrs)
    |> render_submit()

    assert updated_policy = Repo.get_by(Portal.Policy, id: policy.id)

    assert_redirected(lv, ~p"/#{account}/policies/#{updated_policy.id}")
  end

  test "allows reattaching policy to a group when group_idp_id is nil", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    policy = Repo.update!(Ecto.Changeset.change(policy, group_id: nil, group_idp_id: nil))
    group = group_fixture(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    lv
    |> form("form[phx-submit=submit]", policy: %{group_id: group.id})
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/policies/#{policy}")

    assert updated_policy = Repo.get_by(Portal.Policy, id: policy.id)
    assert updated_policy.group_id == group.id
  end

  test "sets group_idp_id when changing to a synced group", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    synced_group = synced_group_fixture(account: account, idp_id: "synced_123")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    lv
    |> form("form[phx-submit=submit]", policy: %{group_id: synced_group.id})
    |> render_submit()

    assert updated_policy = Repo.get_by(Portal.Policy, id: policy.id)
    assert updated_policy.group_id == synced_group.id
    assert updated_policy.group_idp_id == "synced_123"
  end

  test "clears group_idp_id when changing to a non-synced group", %{
    account: account,
    actor: actor,
    policy: policy,
    conn: conn
  } do
    policy = Repo.update!(Ecto.Changeset.change(policy, group_idp_id: "stale_synced_id"))
    static_group = group_fixture(account: account, type: :static, idp_id: nil)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    lv
    |> form("form[phx-submit=submit]", policy: %{group_id: static_group.id})
    |> render_submit()

    assert updated_policy = Repo.get_by(Portal.Policy, id: policy.id)
    assert updated_policy.group_id == static_group.id
    assert updated_policy.group_idp_id == nil
  end
end
