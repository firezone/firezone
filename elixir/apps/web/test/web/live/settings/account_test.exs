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
          monthly_active_users_count: 100
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

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
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
      |> live(~p"/#{account}/settings/account")

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
      |> live(~p"/#{account}/settings/account")

    html = lv |> render()
    assert html =~ "This account has been disabled."
    assert html =~ "contact support"
  end

  test "renders notification settings for account", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/account")

    html = lv |> render()
    assert html =~ "Gateway Upgrade Available"
  end

  test "sends account deletion email", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/account")

    assert lv
           |> element("button[type=submit]", "Delete Account")
           |> render_click()
           |> element_to_text() =~ "A request has been sent to delete your account"

    assert_email_sent(fn email ->
      assert email.subject == "ACCOUNT DELETE REQUEST - #{account.id}"
      assert email.text_body =~ "#{account.id}"
      assert email.text_body =~ "#{identity.actor_id}"
    end)
  end
end
