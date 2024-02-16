defmodule Web.Live.Settings.AccountTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account =
      Fixtures.Accounts.create_account(
        metadata: %{
          stripe: %{
            customer_id: "cus_NffrFeUfNV2Hib",
            subscription_id: "sub_NffrFeUfNV2Hib",
            product_name: "Enterprise"
          }
        },
        limits: %{
          monthly_active_actors_count: 100
        }
      )

    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/settings/account"

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
      |> live(~p"/#{account}/settings/account")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Account Settings"
  end

  test "renders table with account information even if billing portal is down", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/account")

    rows =
      lv
      |> element("#account")
      |> render()
      |> vertical_table_to_map()

    assert rows["account name"] == account.name
    assert rows["account id"] == account.id
    assert rows["account slug"] =~ account.slug
    assert rows["current plan"] =~ account.metadata.stripe.product_name
    assert rows["current plan"] =~ "Billing portal is temporarily unavailable"
    assert rows["seats"] == "0 used / 100 purchased"
  end

  test "renders billing portal url when it's available", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Bypass.open()
    |> Mocks.Stripe.mock_create_billing_session_endpoint(account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/account")

    rows =
      lv
      |> element("#account")
      |> render()
      |> vertical_table_to_map()

    assert rows["current plan"] =~ account.metadata.stripe.product_name
    assert rows["current plan"] =~ "(manage)"
  end

  test "renders error when seats limit is exceeded", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account =
      Fixtures.Accounts.update_account(account, %{
        limits: %{monthly_active_actors_count: 0}
      })

    actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)

    Fixtures.Clients.create_client(
      account: account,
      actor: actor,
      last_seen_at: DateTime.utc_now()
    )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/account")

    rows =
      lv
      |> element("#account")
      |> render()
      |> vertical_table_to_map()

    assert rows["seats"] == "1 used / 0 purchased"

    html = lv |> render()
    assert html =~ "You have reached your monthly active actors limit."
    assert html =~ "upgrade your plan"
  end

  test "renders error when account is disabled", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account =
      Fixtures.Accounts.update_account(account, %{
        disabled_at: DateTime.utc_now()
      })

    actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)

    Fixtures.Clients.create_client(
      account: account,
      actor: actor,
      last_seen_at: DateTime.utc_now()
    )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/account")

    html = lv |> render()
    assert html =~ "This account has been disabled."
    assert html =~ "contact support"
  end
end
