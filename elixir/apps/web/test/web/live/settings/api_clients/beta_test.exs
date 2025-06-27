defmodule Web.Live.Settings.ApiClients.BetaTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      actor: actor,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/settings/api_clients/beta"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "redirects to API client index when feature enabled", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    assert {:error, {:live_redirect, %{to: path, flash: _}}} =
             conn
             |> authorize_conn(identity)
             |> live(~p"/#{account}/settings/api_clients/beta")

    assert path == ~p"/#{account}/settings/api_clients"
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    features = Map.from_struct(account.features)
    attrs = %{features: %{features | rest_api: false}}

    {:ok, account} = Domain.Accounts.update_account(account, attrs)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/beta")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
    assert breadcrumbs =~ "Beta"
  end

  test "sends beta request email", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      features: %{
        rest_api: false,
        traffic_filters: true,
        policy_conditions: true,
        multi_site_resources: true,
        idp_sync: true
      }
    }

    {:ok, account} = Domain.Accounts.update_account(account, attrs)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/beta")

    assert lv
           |> element("#beta-request")
           |> render_click()
           |> Floki.find(".flash-info")
           |> element_to_text() =~ "request to join"

    assert_email_sent(fn email ->
      assert email.subject == "REST API Beta Request - #{account.slug}"
      assert email.text_body =~ "REST API Beta Request"
      assert email.text_body =~ "#{account.id}"
      assert email.text_body =~ "#{account.slug}"
    end)
  end
end
