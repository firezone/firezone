defmodule PortalWeb.SignInTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  @client_sign_in_types ["client", "gui-client", "headless-client"]

  setup do
    account = account_fixture()
    %{account: account}
  end

  describe "mount" do
    test "renders sign-in page with account name", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

      assert html =~ "Sign in to #{account.name}"
    end

    test "renders email OTP form when email OTP provider is configured",
         %{conn: conn, account: account} do
      _provider = email_otp_provider_fixture(account: account)

      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

      assert html =~ "Send code"
    end

    test "renders a GitHub sign-in button when a GitHub provider is configured",
         %{conn: conn, account: account} do
      provider = github_provider_fixture(account: account, name: "GitHub")

      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

      assert html =~ "/#{account.slug}/sign_in/github/#{provider.id}"
      assert html =~ "ri-github-fill"
    end

    test "badges only the last used sign-in method", %{conn: conn, account: account} do
      github = github_provider_fixture(account: account, name: "GitHub")
      _google = google_provider_fixture(account: account, name: "Google")

      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")
      refute html =~ "Last used"

      conn = PortalWeb.Cookie.LastUsedProvider.put(conn, github.id)
      cookie = conn.resp_cookies["last_used_provider"].value

      {:ok, _lv, html} =
        build_conn()
        |> Plug.Test.put_req_cookie("last_used_provider", cookie)
        |> live(~p"/#{account}/sign_in")

      assert length(String.split(html, "Last used")) == 2
    end

    test "does not badge the last used method when it is the only one",
         %{conn: conn, account: account} do
      github = github_provider_fixture(account: account, name: "GitHub")

      conn = PortalWeb.Cookie.LastUsedProvider.put(conn, github.id)
      cookie = conn.resp_cookies["last_used_provider"].value

      {:ok, _lv, html} =
        build_conn()
        |> Plug.Test.put_req_cookie("last_used_provider", cookie)
        |> live(~p"/#{account}/sign_in")

      refute html =~ "Last used"
    end

    test "does not show email OTP form when no providers configured",
         %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

      refute html =~ "Send code"
    end

    test "shows the client sign-in hint for browser sign-in", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

      assert html =~ "Meant to sign in from a client instead?"
    end

    test "hides the client sign-in hint during client sign-in", %{conn: conn, account: account} do
      for client <- @client_sign_in_types do
        {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in?as=#{client}")

        refute html =~ "Meant to sign in from a client instead?"
      end
    end

    test "redirects missing client account slug to root /sign_in with params preserved", %{conn: conn} do
      for client <- @client_sign_in_types do
        params = %{
          "as" => client,
          "state" => "abc",
          "nonce" => "xyz",
          "redirect_to" => "/sites"
        }

        conn = get(conn, ~p"/nonexistent-account/sign_in?#{params}")
        assert redirected_to(conn) == ~p"/sign_in?#{params}"
      end
    end
  end
end
