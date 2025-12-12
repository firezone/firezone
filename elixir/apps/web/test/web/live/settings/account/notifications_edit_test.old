defmodule Web.Live.Settings.Account.NotificationsEditTest do
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
    path = ~p"/#{account}/settings/account/notifications/edit"

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
      |> live(~p"/#{account}/settings/account/notifications/edit")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Account Settings"
    assert breadcrumbs =~ "Edit Notifications"
  end

  test "renders enable/disable form", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/account/notifications/edit")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "account[config][_persistent_id]",
             "account[config][notifications][_persistent_id]",
             "account[config][notifications][outdated_gateway][_persistent_id]",
             "account[config][notifications][outdated_gateway][enabled]"
           ]
  end

  test "updates notifications status on valid attrs", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      "config" => %{
        "_persistent_id" => "0",
        "notifications" => %{
          "_persistent_id" => "0",
          "outdated_gateway" => %{"_persistent_id" => "0", "enabled" => "true"}
        }
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/account/notifications/edit")

    lv
    |> form("form", account: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/settings/account")

    assert account = Repo.get_by(Domain.Account, id: account.id)
    assert account.config.notifications.outdated_gateway.enabled == true
  end
end
