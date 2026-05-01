defmodule PortalWeb.HomeControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures

  @client_sign_in_types ["client", "gui-client", "headless-client"]

  describe "home/2" do
    test "redirects to /getting_started when no cookie present", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/getting_started"
    end

    test "redirects to /sign_in when recent_accounts cookie present", %{conn: conn} do
      account = account_fixture()

      cookie_conn =
        PortalWeb.Cookie.RecentAccounts.put(conn, %PortalWeb.Cookie.RecentAccounts{
          account_ids: [account.id]
        })

      %{value: signed_value} = cookie_conn.resp_cookies["recent_accounts"]

      conn =
        conn
        |> put_req_cookie("recent_accounts", signed_value)
        |> get(~p"/")

      assert redirected_to(conn) == ~p"/sign_in"
    end

    test "redirects client sign-in without slug to /sign_in and preserves all sign-in params", %{
      conn: conn
    } do
      for client <- @client_sign_in_types do
        params = %{
          "as" => client,
          "state" => "abc",
          "nonce" => "xyz",
          "redirect_to" => "/sites"
        }

        conn = get(conn, ~p"/?#{params}")
        assert redirected_to(conn) == ~p"/sign_in?#{params}"
      end
    end
  end

  describe "getting_started/2" do
    test "renders 'getting started' page", %{conn: conn} do
      conn = get(conn, ~p"/getting_started")
      html = response(conn, 200)

      assert html =~ "Let's get started!"
      assert html =~ "Which best describes why you're here?"
      assert html =~ "My company uses Firezone"
      refute html =~ "Sign in to Firezone"
    end
  end

  describe "sign_in_chooser/2" do
    test "renders account chooser without accounts when no cookie", %{conn: conn} do
      conn = get(conn, ~p"/sign_in")
      html = response(conn, 200)

      assert html =~ "Sign in to Firezone"
      refute html =~ "Recently signed in"
    end

    test "renders account chooser with recent accounts when cookie present", %{conn: conn} do
      account = account_fixture()

      cookie_conn =
        PortalWeb.Cookie.RecentAccounts.put(conn, %PortalWeb.Cookie.RecentAccounts{
          account_ids: [account.id]
        })

      %{value: signed_value} = cookie_conn.resp_cookies["recent_accounts"]

      conn =
        conn
        |> put_req_cookie("recent_accounts", signed_value)
        |> get(~p"/sign_in")

      html = response(conn, 200)

      assert html =~ "Sign in to Firezone"
      assert html =~ "Recently signed in"
      assert html =~ account.name
      assert html =~ ~p"/#{account.slug}/sign_in"
    end

    test "renders multiple recent accounts", %{conn: conn} do
      accounts = [account_fixture(), account_fixture()]
      account_ids = Enum.map(accounts, & &1.id)

      cookie_conn =
        PortalWeb.Cookie.RecentAccounts.put(conn, %PortalWeb.Cookie.RecentAccounts{
          account_ids: account_ids
        })

      %{value: signed_value} = cookie_conn.resp_cookies["recent_accounts"]

      conn =
        conn
        |> put_req_cookie("recent_accounts", signed_value)
        |> get(~p"/sign_in")

      html = response(conn, 200)

      for account <- accounts do
        assert html =~ account.name
        assert html =~ ~p"/#{account.slug}/sign_in"
      end
    end

    test "hides portal-only links for client sign-in", %{conn: conn} do
      for client <- @client_sign_in_types do
        conn = get(conn, ~p"/sign_in?#{%{"as" => client}}")
        html = response(conn, 200)

        refute html =~ "Want to set up a new Organization?"
        refute html =~ "Not sure where to start?"
      end
    end
  end

  describe "redirect_to_sign_in/2" do
    test "redirects to the account sign-in page via POST /sign_in and preserves all sign-in params",
         %{conn: conn} do
      id = Ecto.UUID.generate()

      for client <- @client_sign_in_types do
        params = %{
          "account_id_or_slug" => id,
          "as" => client,
          "state" => "abc",
          "nonce" => "xyz",
          "redirect_to" => "/sites"
        }

        conn = post(conn, ~p"/sign_in", params)
        expected_params = Map.drop(params, ["account_id_or_slug"])
        assert redirected_to(conn) == ~p"/#{id}/sign_in?#{expected_params}"
      end
    end

    test "redirects to the account sign-in page via POST / and preserves all sign-in params", %{
      conn: conn
    } do
      id = Ecto.UUID.generate()

      for client <- @client_sign_in_types do
        params = %{
          "account_id_or_slug" => id,
          "as" => client,
          "state" => "abc",
          "nonce" => "xyz",
          "redirect_to" => "/sites"
        }

        conn = post(conn, ~p"/", params)
        expected_params = Map.drop(params, ["account_id_or_slug"])
        assert redirected_to(conn) == ~p"/#{id}/sign_in?#{expected_params}"
      end
    end

    test "downcases account slug on redirect", %{conn: conn} do
      conn = post(conn, ~p"/sign_in", %{"account_id_or_slug" => "FOO", "as" => "client"})
      assert redirected_to(conn) == ~p"/foo/sign_in?as=client"
    end

    test "puts an error flash when slug is invalid", %{conn: conn} do
      conn = post(conn, ~p"/sign_in", %{"account_id_or_slug" => "?1", "as" => "client"})
      assert redirected_to(conn) == ~p"/sign_in?as=client"

      assert conn.assigns.flash["error"] ==
               "Account ID or Slug can only contain letters, digits and underscore"
    end
  end
end
