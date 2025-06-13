defmodule Web.Live.Policies.IndexTest do
  use Web.ConnCase, async: true
  alias Domain.Events

  setup do
    account = Fixtures.Accounts.create_account()
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/policies"

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
      |> live(~p"/#{account}/policies")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Policies"
  end

  test "renders add policy button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies")

    assert button = Floki.find(html, "a[href='/#{account.slug}/policies/new']")
    assert Floki.text(button) =~ "Add Policy"
  end

  test "renders policies table", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    policy =
      Fixtures.Policies.create_policy(account: account, description: "foo bar")
      |> Domain.Repo.preload(:actor_group)
      |> Domain.Repo.preload(:resource)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies")

    [rendered_policy | _] =
      lv
      |> element("#policies")
      |> render()
      |> table_to_map()

    assert rendered_policy["id"] =~ policy.id
    assert rendered_policy["group"] =~ policy.actor_group.name
    assert rendered_policy["resource"] =~ policy.resource.name
  end

  describe "handle_info/2" do
    test "Shows reload button when policy is created", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/policies")

      refute html =~ "The table data has changed."
      refute html =~ "reload-btn"

      policy = Fixtures.Policies.create_policy(account: account, description: "foo bar")

      Events.Hooks.Policies.on_insert(%{
        "id" => policy.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "account_id" => account.id
      })

      reload_btn =
        lv
        |> element("#policies-reload-btn")
        |> render()

      assert reload_btn
    end

    test "Shows reload button when policy is deleted", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      policy = Fixtures.Policies.create_policy(account: account, description: "foo bar")
      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/policies")

      refute html =~ "The table data has changed."
      refute html =~ "reload-btn"

      Domain.Policies.delete_policy(policy, subject)

      Events.Hooks.Policies.on_delete(%{
        "id" => policy.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "account_id" => account.id
      })

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)

      reload_btn =
        lv
        |> element("#policies-reload-btn")
        |> render()

      assert reload_btn
    end
  end
end
