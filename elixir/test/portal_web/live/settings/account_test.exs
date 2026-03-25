defmodule PortalWeb.Live.Settings.AccountTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers

  setup do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)

    %{
      account: account,
      actor: actor
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/settings/account"

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
      |> live(~p"/#{account}/settings/account")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Account Settings"
  end

  test "renders table with account information", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
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

  test "renders notification settings for account", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/account")

    html = lv |> render()
    assert html =~ "Gateway Upgrade Available"
  end

  test "sends account deletion email", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/account")

    assert lv
           |> element("button[type=submit]", "Delete Account")
           |> render_click()
           |> element_to_text() =~ "A request has been sent to delete your account"

    assert_email_queued(account.id, fn email ->
      assert email.subject == "ACCOUNT DELETE REQUEST - #{account.id}"
      assert email.text_body =~ "#{account.id}"
      assert email.text_body =~ "#{actor.id}"
    end)
  end
end
