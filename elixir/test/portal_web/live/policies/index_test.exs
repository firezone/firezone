defmodule PortalWeb.Live.Policies.IndexTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.Changes.Change

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.PolicyFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/policies"

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
      |> live(~p"/#{account}/policies")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Policies"
  end

  test "renders add policy button", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies")

    assert button =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a[href='/#{account.slug}/policies/new']")

    assert Floki.text(button) =~ "Add Policy"
  end

  test "renders policies table", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    policy =
      policy_fixture(account: account, description: "foo bar")
      |> Repo.preload([:group, :resource])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies")

    [rendered_policy | _] =
      lv
      |> element("#policies")
      |> render()
      |> table_to_map()

    assert rendered_policy["id"] =~ policy.id
    assert rendered_policy["group"] =~ policy.group.name
    assert rendered_policy["resource"] =~ policy.resource.name
  end

  test "renders empty state when no policies exist", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/policies")

    assert html =~ "No policies to display"
    assert html =~ "Add a policy"
  end

  describe "handle_info/2" do
    test "shows reload button when policy is created", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies")

      refute html =~ "policies-reload-btn"

      policy = policy_fixture(account: account, description: "foo bar")

      send(lv.pid, %Change{
        struct: policy,
        op: :insert
      })

      html = render(lv)
      assert html =~ "policies-reload-btn"
    end

    test "shows reload button when policy is deleted", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      policy = policy_fixture(account: account, description: "foo bar")

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies")

      refute html =~ "policies-reload-btn"

      send(lv.pid, %Change{
        old_struct: policy,
        op: :delete
      })

      html = render(lv)
      assert html =~ "policies-reload-btn"
    end

    test "shows reload button when policy is updated", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      policy = policy_fixture(account: account, description: "foo bar")

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies")

      refute html =~ "policies-reload-btn"

      send(lv.pid, %Change{
        struct: %{policy | description: "updated"},
        old_struct: policy,
        op: :update
      })

      html = render(lv)
      assert html =~ "policies-reload-btn"
    end
  end
end
