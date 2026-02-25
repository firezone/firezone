defmodule PortalWeb.Plugs.AutoRedirectDefaultProviderTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  alias PortalWeb.Plugs.AutoRedirectDefaultProvider

  setup do
    account = account_fixture()
    {:ok, account: account}
  end

  describe "call/2" do
    for as_value <- ["client", "headless-client", "gui-client"] do
      test "redirects to default OIDC provider when as=#{as_value}", %{
        conn: conn,
        account: account
      } do
        as_value = unquote(as_value)
        provider = oidc_provider_fixture(account: account, is_default: true)

        conn =
          conn
          |> Map.put(:params, %{"as" => as_value, "account_id_or_slug" => account.slug})
          |> Map.put(:path_info, [account.slug])
          |> Map.put(:query_string, "as=#{as_value}&state=test-state")
          |> AutoRedirectDefaultProvider.call([])

        assert conn.halted
        location = redirected_to(conn)
        assert location =~ "/sign_in/oidc/#{provider.id}"
        assert location =~ "as=#{as_value}"
        assert location =~ "state=test-state"
      end

      test "redirects to default Google provider when as=#{as_value}", %{
        conn: conn,
        account: account
      } do
        as_value = unquote(as_value)
        provider = google_provider_fixture(account: account, is_default: true)

        conn =
          conn
          |> Map.put(:params, %{"as" => as_value, "account_id_or_slug" => account.slug})
          |> Map.put(:path_info, [account.slug])
          |> Map.put(:query_string, "as=#{as_value}")
          |> AutoRedirectDefaultProvider.call([])

        assert conn.halted
        location = redirected_to(conn)
        assert location =~ "/sign_in/google/#{provider.id}"
      end

      test "redirects to default Entra provider when as=#{as_value}", %{
        conn: conn,
        account: account
      } do
        as_value = unquote(as_value)
        provider = entra_provider_fixture(account: account, is_default: true)

        conn =
          conn
          |> Map.put(:params, %{"as" => as_value, "account_id_or_slug" => account.slug})
          |> Map.put(:path_info, [account.slug])
          |> Map.put(:query_string, "as=#{as_value}")
          |> AutoRedirectDefaultProvider.call([])

        assert conn.halted
        location = redirected_to(conn)
        assert location =~ "/sign_in/entra/#{provider.id}"
      end

      test "redirects to default Okta provider when as=#{as_value}", %{
        conn: conn,
        account: account
      } do
        as_value = unquote(as_value)
        provider = okta_provider_fixture(account: account, is_default: true)

        conn =
          conn
          |> Map.put(:params, %{"as" => as_value, "account_id_or_slug" => account.slug})
          |> Map.put(:path_info, [account.slug])
          |> Map.put(:query_string, "as=#{as_value}")
          |> AutoRedirectDefaultProvider.call([])

        assert conn.halted
        location = redirected_to(conn)
        assert location =~ "/sign_in/okta/#{provider.id}"
      end
    end

    test "does not redirect when as is not a client type", %{conn: conn, account: account} do
      _provider = oidc_provider_fixture(account: account, is_default: true)

      conn =
        conn
        |> Map.put(:params, %{"as" => "browser", "account_id_or_slug" => account.slug})
        |> Map.put(:path_info, [account.slug])
        |> AutoRedirectDefaultProvider.call([])

      refute conn.halted
    end

    test "does not redirect when as param is missing", %{conn: conn, account: account} do
      _provider = oidc_provider_fixture(account: account, is_default: true)

      conn =
        conn
        |> Map.put(:params, %{"account_id_or_slug" => account.slug})
        |> Map.put(:path_info, [account.slug])
        |> AutoRedirectDefaultProvider.call([])

      refute conn.halted
    end

    test "does not redirect when no default provider exists", %{conn: conn, account: account} do
      _provider = oidc_provider_fixture(account: account, is_default: false)

      conn =
        conn
        |> Map.put(:params, %{"as" => "client", "account_id_or_slug" => account.slug})
        |> Map.put(:path_info, [account.slug])
        |> AutoRedirectDefaultProvider.call([])

      refute conn.halted
    end

    test "does not redirect when provider is disabled", %{conn: conn, account: account} do
      _provider = oidc_provider_fixture(account: account, is_default: true, is_disabled: true)

      conn =
        conn
        |> Map.put(:params, %{"as" => "client", "account_id_or_slug" => account.slug})
        |> Map.put(:path_info, [account.slug])
        |> AutoRedirectDefaultProvider.call([])

      refute conn.halted
    end

    test "does not redirect when account is not found", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{"as" => "client", "account_id_or_slug" => "nonexistent-slug"})
        |> Map.put(:path_info, ["nonexistent-slug"])
        |> AutoRedirectDefaultProvider.call([])

      refute conn.halted
    end

    test "does not redirect when path_info has more than one segment", %{
      conn: conn,
      account: account
    } do
      _provider = oidc_provider_fixture(account: account, is_default: true)

      conn =
        conn
        |> Map.put(:params, %{"as" => "client", "account_id_or_slug" => account.slug})
        |> Map.put(:path_info, [account.slug, "sign_in"])
        |> AutoRedirectDefaultProvider.call([])

      refute conn.halted
    end

    test "redirects without query string when query_string is empty", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, is_default: true)

      conn =
        conn
        |> Map.put(:params, %{"as" => "client", "account_id_or_slug" => account.slug})
        |> Map.put(:path_info, [account.slug])
        |> Map.put(:query_string, "")
        |> AutoRedirectDefaultProvider.call([])

      assert conn.halted
      location = redirected_to(conn)
      assert location =~ "/sign_in/oidc/#{provider.id}"
      refute location =~ "?"
    end

    test "looks up account by ID when account_id_or_slug is a UUID", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, is_default: true)

      conn =
        conn
        |> Map.put(:params, %{"as" => "client", "account_id_or_slug" => account.id})
        |> Map.put(:path_info, [account.id])
        |> AutoRedirectDefaultProvider.call([])

      assert conn.halted
      location = redirected_to(conn)
      assert location =~ "/sign_in/oidc/#{provider.id}"
    end
  end

  describe "integration" do
    test "as=client auto-redirects to default OIDC provider with params preserved", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, is_default: true)

      conn = get(conn, ~p"/#{account.slug}?as=client&nonce=test-nonce&state=test-state")

      location = redirected_to(conn)
      assert location =~ "/sign_in/oidc/#{provider.id}"
      assert location =~ "as=client"
      assert location =~ "nonce=test-nonce"
      assert location =~ "state=test-state"
    end

    test "as=headless-client auto-redirects to default OIDC provider with params preserved", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, is_default: true)

      conn = get(conn, ~p"/#{account.slug}?as=headless-client&state=test-state")

      location = redirected_to(conn)
      assert location =~ "/sign_in/oidc/#{provider.id}"
      assert location =~ "as=headless-client"
      assert location =~ "state=test-state"
    end

    test "as=gui-client auto-redirects to default OIDC provider with params preserved", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, is_default: true)

      conn = get(conn, ~p"/#{account.slug}?as=gui-client&nonce=test-nonce&state=test-state")

      location = redirected_to(conn)
      assert location =~ "/sign_in/oidc/#{provider.id}"
      assert location =~ "as=gui-client"
      assert location =~ "nonce=test-nonce"
      assert location =~ "state=test-state"
    end

    test "does not redirect when no default provider", %{conn: conn, account: account} do
      _provider = oidc_provider_fixture(account: account, is_default: false)

      conn = get(conn, ~p"/#{account.slug}?as=client&state=test-state")

      assert html_response(conn, 200) =~ "Sign In"
    end
  end
end
