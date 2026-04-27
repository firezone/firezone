defmodule PortalWeb.Settings.ApiClients.BetaTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias Portal.Account

  setup do
    # Disable rest_api feature so the account lands on the beta page instead of index
    account = account_fixture(features: %{rest_api: false})
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/api_clients/beta"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "index (default action)" do
    test "redirects to api clients index when rest api is enabled", %{conn: conn} do
      account = account_fixture(features: %{rest_api: true})
      actor = admin_actor_fixture(account: account)

      assert {:error, {:live_redirect, %{to: to}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/settings/api_clients/beta")

      assert to == ~p"/#{account}/settings/api_clients"
    end

    test "renders REST API beta info page", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/beta")

      assert html =~ "REST API is in closed beta"
      assert html =~ "Request access"
      assert html =~ "swaggerui"
    end

    test "shows access request submitted after requesting", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/beta")

      html = render_click(lv, "request_access")
      assert html =~ "Access request submitted"
      refute html =~ "Request access"

      assert %Account{} = saved = Repo.get!(Account, account.id)
      assert saved.metadata.rest_api_requested_at
    end

    test "renders requested state when access was already requested", %{conn: conn} do
      account =
        account_fixture(
          features: %{rest_api: false},
          metadata: %{rest_api_requested_at: DateTime.utc_now(), stripe: %{}}
        )

      actor = admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/beta")

      assert html =~ "Access request submitted."
      refute html =~ "Request access"
    end
  end
end
