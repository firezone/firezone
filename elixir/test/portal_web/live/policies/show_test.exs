defmodule PortalWeb.Live.Policies.ShowTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.PolicyFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.ResourceFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    resource = resource_fixture(account: account)

    %{
      account: account,
      actor: actor,
      resource: resource
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    resource: resource,
    conn: conn
  } do
    policy = policy_fixture(account: account, resource: resource)

    path = ~p"/#{account}/policies/#{policy}"

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
    resource: resource,
    actor: actor,
    conn: conn
  } do
    policy = policy_fixture(account: account, resource: resource)
    Repo.delete!(policy)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies/#{policy}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    resource: resource,
    actor: actor,
    conn: conn
  } do
    conn = authorize_conn(conn, actor)
    policy = create_simple_policy(account, resource)

    {:ok, _lv, html} = live(conn, ~p"/#{account}/policies/#{policy}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Policies"
    assert breadcrumbs =~ policy.group.name
    assert breadcrumbs =~ policy.resource.name
  end

  test "allows editing policy", %{
    account: account,
    resource: resource,
    actor: actor,
    conn: conn
  } do
    conn = authorize_conn(conn, actor)
    policy = create_simple_policy(account, resource)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/policies/#{policy}")

    assert lv
           |> element("a", "Edit Policy")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/policies/#{policy}/edit", kind: :push}}}
  end

  test "renders policy details with conditions", %{
    account: account,
    resource: resource,
    actor: actor,
    conn: conn
  } do
    conn = authorize_conn(conn, actor)
    policy = create_policy_with_conditions(account, resource)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/policies/#{policy}")

    table =
      lv
      |> element("#policy")
      |> render()
      |> vertical_table_to_map()

    assert table["group"] =~ policy.group.name
    assert table["resource"] =~ policy.resource.name
    assert table["description"] =~ policy.description

    assert table["conditions"] =~ "This policy can be used on"
    assert table["conditions"] =~ "Mondays"
    assert table["conditions"] =~ "Wednesdays"
    assert table["conditions"] =~ "Saturdays (10:00:00 - 15:00:00 UTC)"
    assert table["conditions"] =~ "Sundays (23:00:00 - 23:59:59 UTC)"
    assert table["conditions"] =~ "from United States of America"
    assert table["conditions"] =~ "from IP addresses that are"
    assert table["conditions"] =~ "not in"
    assert table["conditions"] =~ "0.0.0.0"
    assert table["conditions"] =~ "when signed in"
    assert table["conditions"] =~ "with"
    assert table["conditions"] =~ "provider(s)"
  end

  test "renders policy details for policy created by API client", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    api_actor = api_client_fixture(account: account)

    conn = authorize_conn(conn, actor)
    policy = create_simple_policy(account, resource)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/policies/#{policy}")

    table =
      lv
      |> element("#policy")
      |> render()
      |> vertical_table_to_map()

    assert table["group"] =~ policy.group.name
    assert table["resource"] =~ policy.resource.name

    # API client name should not appear in the table since we didn't use api_actor as subject
    refute Map.get(table, "created", "") =~ api_actor.name
  end

  test "renders policy authorizations table", %{
    account: account,
    actor: actor,
    resource: resource,
    conn: conn
  } do
    conn = authorize_conn(conn, actor)
    policy = create_simple_policy(account, resource)

    policy_authorization =
      policy_authorization_fixture(
        account: account,
        resource: resource,
        policy: policy
      )

    policy_authorization = Repo.preload(policy_authorization, client: [:actor], gateway: [:site])

    {:ok, lv, _html} = live(conn, ~p"/#{account}/policies/#{policy}")

    [row] =
      lv
      |> element("#policy_authorizations")
      |> render()
      |> table_to_map()

    assert row["authorized"]
    assert row["client, actor"] =~ policy_authorization.client.name
    assert row["client, actor"] =~ "owned by #{policy_authorization.client.actor.name}"
    assert row["client, actor"] =~ to_string(policy_authorization.client_remote_ip)

    assert row["gateway"] =~
             "#{policy_authorization.gateway.site.name}-#{policy_authorization.gateway.name}"

    assert row["gateway"] =~ to_string(policy_authorization.gateway_remote_ip)
  end

  test "renders empty state when no policy authorizations exist", %{
    account: account,
    resource: resource,
    actor: actor,
    conn: conn
  } do
    conn = authorize_conn(conn, actor)
    policy = create_simple_policy(account, resource)

    {:ok, _lv, html} = live(conn, ~p"/#{account}/policies/#{policy}")

    assert html =~ "No activity to display"
  end

  test "allows deleting policy", %{
    account: account,
    resource: resource,
    actor: actor,
    conn: conn
  } do
    conn = authorize_conn(conn, actor)
    policy = create_simple_policy(account, resource)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/policies/#{policy}")

    expected_path = ~p"/#{account}/policies"

    assert {:error, {:live_redirect, %{to: ^expected_path, kind: :push}}} =
             lv
             |> element("button[type=submit]", "Delete Policy")
             |> render_click()

    refute Repo.get_by(Portal.Policy, id: policy.id)
  end

  test "allows disabling and enabling policy", %{
    account: account,
    resource: resource,
    actor: actor,
    conn: conn
  } do
    conn = authorize_conn(conn, actor)
    policy = create_simple_policy(account, resource)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/policies/#{policy}")

    assert lv
           |> element("button[type=submit]", "Disable")
           |> render_click() =~ "(disabled)"

    assert Repo.get_by(Portal.Policy, id: policy.id).disabled_at

    refute lv
           |> element("button[type=submit]", "Enable")
           |> render_click() =~ "(disabled)"

    refute Repo.get_by(Portal.Policy, id: policy.id).disabled_at
  end

  # Helper functions

  defp create_policy_with_conditions(account, resource) do
    # Get the provider that authorize_conn created for this account
    provider = Repo.get_by!(Portal.EmailOTP.AuthProvider, account_id: account.id)

    policy =
      policy_fixture(
        account: account,
        resource: resource,
        conditions: [
          %{
            property: :current_utc_datetime,
            operator: :is_in_day_of_week_time_ranges,
            values: [
              "M/true/UTC",
              "T//UTC",
              "W/true/UTC",
              "R//UTC",
              "F//UTC",
              "S/10:00:00-15:00:00/UTC",
              "U/23:00:00-23:59:59/UTC"
            ]
          },
          %{
            property: :auth_provider_id,
            operator: :is_in,
            values: [provider.id]
          },
          %{
            property: :remote_ip,
            operator: :is_not_in_cidr,
            values: ["0.0.0.0/0"]
          },
          %{
            property: :remote_ip_location_region,
            operator: :is_in,
            values: ["US"]
          }
        ],
        description: "Test Policy"
      )

    Repo.preload(policy, [:group, :resource])
  end

  defp create_simple_policy(account, resource) do
    policy = policy_fixture(account: account, resource: resource, description: "Test Policy")
    Repo.preload(policy, [:group, :resource])
  end
end
