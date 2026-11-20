defmodule PortalWeb.HomeControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures

  @client_sign_in_types ["client", "gui-client", "headless-client"]
  @website_distinct_id "7d2ed047-64d3-41f9-9a41-ac2c9b92e761"

  describe "website attribution" do
    setup %{conn: conn} do
      %{conn: put_req_header(conn, "x-geo-location-region", "US")}
    end

    test "stores attribution and redirects sign-up links to a clean URL", %{conn: conn} do
      conn =
        get(
          conn,
          "/sign_up?fz_website_id=#{@website_distinct_id}&fz_website_path=%2Fpricing"
        )

      assert redirected_to(conn) == "/sign_up"

      assert %{"marketing" => marketing} = attribution = get_session(conn, "website_attribution")

      assert Map.delete(attribution, "marketing") == %{
               "distinct_id" => @website_distinct_id,
               "source" => "www.firezone.dev",
               "website_path" => "/pricing"
             }

      assert %{"marketing_allowed" => true, "source" => "region", "captured_at" => captured_at} =
               marketing

      assert is_integer(captured_at)
    end

    test "preserves unrelated sign-in parameters while removing attribution", %{conn: conn} do
      conn =
        get(
          conn,
          "/sign_in?as=gui-client&fz_website_id=#{@website_distinct_id}&fz_website_path=%2F"
        )

      assert redirected_to(conn) == "/sign_in?as=gui-client"
    end

    test "removes invalid website attribution while retaining the regional marketing default", %{conn: conn} do
      conn = get(conn, "/sign_up?fz_website_id=invalid&fz_website_path=%2Fpricing")

      assert redirected_to(conn) == "/sign_up"
      assert %{"marketing" => marketing} = attribution = get_session(conn, "website_attribution")
      assert Map.keys(attribution) == ["marketing"]

      assert %{"marketing_allowed" => true, "source" => "region", "captured_at" => captured_at} =
               marketing

      assert is_integer(captured_at)
    end
  end

  describe "home/2" do
    test "sends people with no recent accounts to sign-up", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert redirected_to(conn) == ~p"/sign_up"
    end

    test "keeps campaign params, not sign-in params, on the way to sign-up", %{conn: conn} do
      conn = get(conn, ~p"/?#{%{"redirect_to" => "/sites", "utm_source" => "x", "utm_campaign" => ""}}")

      assert redirected_to(conn) == ~p"/sign_up?#{%{"utm_source" => "x"}}"
    end

    test "redirects to /sign_in when recent_accounts cookie present", %{conn: conn} do
      account = account_fixture()

      conn =
        conn
        |> put_recent_accounts([account.id])
        |> get(~p"/")

      assert redirected_to(conn) == ~p"/sign_in"
    end

    test "sends a browser whose recent accounts were all deleted to sign-up and clears them", %{conn: conn} do
      conn = conn |> put_recent_accounts([Ecto.UUID.generate()]) |> get(~p"/")

      assert redirected_to(conn) == ~p"/sign_up"
      assert %{"recent_accounts" => _pruned} = conn.resp_cookies
    end

    test "keeps a browser with at least one remaining account on sign-in", %{conn: conn} do
      account = account_fixture()

      conn = conn |> put_recent_accounts([Ecto.UUID.generate(), account.id]) |> get(~p"/")

      assert redirected_to(conn) == ~p"/sign_in"
    end

    test "redirects clients to /sign_in with or without recent accounts", %{conn: conn} do
      account = account_fixture()

      for client <- @client_sign_in_types, recent <- [[], [account.id]] do
        conn = conn |> put_recent_accounts(recent) |> get(~p"/?#{%{"as" => client}}")

        assert redirected_to(conn) == ~p"/sign_in?#{%{"as" => client}}"
      end
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

    test "sets security headers", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]

      assert get_resp_header(conn, "permissions-policy") == [
               "browsing-topics=(), camera=(), geolocation=(), microphone=(), payment=(), usb=()"
             ]
    end
  end

  describe "region links on the sign-in layout" do
    test "links the same page on the EU portal from the US portal", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :us)
      Portal.Config.put_env_override(:web_external_url, "https://app.firezone.dev")

      html = conn |> get(~p"/sign_in") |> response(200)

      assert html =~ ~s(href="https://eu.app.firezone.dev/sign_in")
    end

    test "links the same page on the US portal from the EU portal", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :eu)
      Portal.Config.put_env_override(:web_external_url, "https://eu.app.firezone.dev")

      html = conn |> get(~p"/sign_in?client_platform=apple") |> response(200)

      assert html =~ ~s(href="https://app.firezone.dev/sign_in?client_platform=apple")
    end

    test "shows no portal link on other portals", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :eu)
      Portal.Config.put_env_override(:web_external_url, "https://eu.app.firez.one")

      html = conn |> get(~p"/sign_in") |> response(200)

      assert html =~ "European Union"
      refute html =~ "other-region-portal"
    end

    test "shows no region links on on-prem portals", %{conn: conn} do
      html = conn |> get(~p"/sign_in") |> response(200)

      refute html =~ "other-region-portal"
    end

  end

  describe "pages this replaced" do
    test "/getting_started redirects home with the sign-in params", %{conn: conn} do
      conn = get(conn, ~p"/getting_started?#{%{"as" => "client", "utm_source" => "x"}}")
      assert redirected_to(conn) == ~p"/?as=client"
    end

    test "/find_account redirects to the sign-in chooser with the sign-in params", %{conn: conn} do
      conn = get(conn, ~p"/find_account?#{%{"redirect_to" => "/sites"}}")
      assert redirected_to(conn) == ~p"/sign_in?redirect_to=%2Fsites"
    end
  end

  describe "remove_recent_account/2" do
    test "forgets one account and keeps the sign-in params", %{conn: conn} do
      [removed, kept] = [account_fixture(), account_fixture()]
      params = %{"as" => "client", "state" => "abc"}

      conn =
        conn
        |> put_recent_accounts([removed.id, kept.id])
        |> post(~p"/sign_in/recent_accounts/#{removed.id}/remove?#{params}")

      assert redirected_to(conn) == ~p"/sign_in?#{params}"

      html = conn |> recycle() |> get(~p"/sign_in") |> html_response(200)
      assert html =~ kept.name
      refute html =~ removed.name
    end

    test "forgetting the last account sends home to sign-up again", %{conn: conn} do
      account = account_fixture()

      conn =
        conn
        |> put_recent_accounts([account.id])
        |> post(~p"/sign_in/recent_accounts/#{account.id}/remove")

      assert redirected_to(conn) == ~p"/sign_in"
      assert conn |> recycle() |> get(~p"/") |> redirected_to() == ~p"/sign_up"
    end

    test "changes nothing for an account that isn't recent or an id that isn't one", %{conn: conn} do
      account = account_fixture()

      for account_id <- [Ecto.UUID.generate(), "not-an-id"] do
        conn =
          conn
          |> put_recent_accounts([account.id])
          |> post(~p"/sign_in/recent_accounts/#{account_id}/remove")

        assert redirected_to(conn) == ~p"/sign_in"
        refute Map.has_key?(conn.resp_cookies, "recent_accounts")
      end
    end

    test "needs the CSRF token, so other sites can't clear the list", %{conn: conn} do
      account = account_fixture()

      conn =
        conn
        |> put_recent_accounts([account.id])
        |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent 403, fn -> post(conn, ~p"/sign_in/recent_accounts/#{account.id}/remove") end
    end
  end

  describe "redirect_to_sign_in/2" do
    test "takes the account from a pasted sign-in URL", %{conn: conn} do
      for input <- [
            "https://app.firezone.dev/acme",
            "https://app.firezone.dev/acme/sign_in",
            "app.firezone.dev/Acme/",
            "http://localhost:13443/acme",
            "  acme/sign_in ",
            "acme"
          ] do
        conn = post(conn, ~p"/sign_in", %{"account_id_or_slug" => input, "as" => "client"})
        assert redirected_to(conn) == ~p"/acme/sign_in?as=client", "for #{inspect(input)}"
      end
    end

    test "rejects a pasted URL with no account in it", %{conn: conn} do
      conn = post(conn, ~p"/sign_in", %{"account_id_or_slug" => "https://app.firezone.dev/", "as" => "client"})

      assert redirected_to(conn) == ~p"/sign_in?as=client"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign-in URLs can only contain"
    end

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
               "Sign-in URLs can only contain letters, digits and underscores"
    end
  end

  describe "malformed input" do
    test "rejects an account chooser value that is not a string", %{conn: conn} do
      assert_error_sent 400, fn ->
        post(conn, ~p"/sign_in", %{"account_id_or_slug" => ["x"]})
      end
    end

    test "redirects attribution links on a doubled slash to a local path", %{conn: conn} do
      conn = get(conn, "http://www.example.com//sign_up?fz_mktg=true")

      assert redirected_to(conn) == "/sign_up"
    end
  end

  defp put_recent_accounts(conn, account_ids) do
    cookie_conn =
      PortalWeb.Cookie.RecentAccounts.put(conn, %PortalWeb.Cookie.RecentAccounts{account_ids: account_ids})

    %{value: signed_value} = cookie_conn.resp_cookies["recent_accounts"]
    put_req_cookie(conn, "recent_accounts", signed_value)
  end
end
