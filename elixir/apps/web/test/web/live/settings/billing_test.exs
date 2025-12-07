defmodule Web.Live.Settings.BillingTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account =
      Fixtures.Accounts.create_account(
        metadata: %{
          stripe: %{
            customer_id: "cus_NffrFeUfNV2Hib",
            subscription_id: "sub_NffrFeUfNV2Hib",
            product_name: "Enterprise",
            billing_email: "foo@example.com"
          }
        },
        limits: %{
          monthly_active_users_count: 100,
          service_accounts_count: 100,
          sites_count: 10,
          account_admin_users_count: 2,
          users_count: 200
        }
      )

    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/settings/billing"

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
      |> live(~p"/#{account}/settings/billing")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Billing"
  end

  test "renders table with account information even if billing portal is down", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/billing")

    rows =
      lv
      |> element("#billing")
      |> render()
      |> vertical_table_to_map()

    assert rows["billing email"] =~ account.metadata.stripe.billing_email
    assert rows["current plan"] =~ account.metadata.stripe.product_name

    rows =
      lv
      |> element("#billing-limits")
      |> render()
      |> vertical_table_to_map()

    assert rows["users"] =~ "1 used / 200 allowed"
    assert rows["seats"] =~ "0 used / 100 allowed"
    assert rows["sites"] =~ "0 used / 10 allowed"
    assert rows["admins"] =~ "1 used / 2 allowed"

    html = element(lv, "button[phx-click='redirect_to_billing_portal']") |> render_click()
    assert html =~ "Billing portal is temporarily unavailable, please try again later."
  end

  test "renders Contact sales link", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/billing")

    assert has_element?(lv, "a[href*='mailto:support']")
    assert html =~ "Contact sales"
  end

  test "renders billing portal button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Bypass.open()
    |> Mocks.Stripe.mock_create_billing_session_endpoint(account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/billing")

    assert has_element?(lv, "button[phx-click='redirect_to_billing_portal']")

    assert {:error, {:redirect, %{to: to}}} =
             element(lv, "button[phx-click='redirect_to_billing_portal']")
             |> render_click()

    assert to =~ "https://billing.stripe.com/p/session"
  end

  test "renders error when limit is exceeded", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account =
      Fixtures.Accounts.update_account(account, %{
        warning: "You have reached your monthly active actors limit."
      })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/billing")

    html = lv |> render()
    assert html =~ "You have reached your monthly active actors limit."
    assert html =~ "check your billing information"
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
      |> live(~p"/#{account}/settings/billing")

    html = lv |> render()
    assert html =~ "This account has been disabled."
    assert html =~ "contact support"
  end
end
