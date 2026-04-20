defmodule PortalWeb.SignInControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    {:ok, account: account}
  end

  describe "client_redirect/2" do
    test "renders 302 with deep link location on proper cookie values", %{
      conn: conn,
      account: account
    } do
      actor = actor_fixture(account: account, type: :account_admin_user)

      client_auth_cookie = %PortalWeb.Cookie.ClientAuth{
        actor_name: actor.name,
        fragment: "test_fragment_value",
        identity_provider_identifier: "user@example.com",
        state: "STATE"
      }

      conn_with_cookie = PortalWeb.Cookie.ClientAuth.put(conn, client_auth_cookie)
      %{value: signed_value} = conn_with_cookie.resp_cookies["client_auth"]

      conn_result =
        conn
        |> put_req_cookie("client_auth", signed_value)
        |> get(~p"/#{account}/sign_in/client_redirect")

      assert redirected_to = redirected_to(conn_result, 302)
      assert redirected_to =~ "firezone-fd0020211111://handle_client_sign_in_callback"

      assert redirected_uri = URI.parse(redirected_to)
      assert query_params = URI.decode_query(redirected_uri.query)
      assert query_params["fragment"] == "test_fragment_value"
      assert query_params["state"] == "STATE"
      assert query_params["actor_name"] == actor.name
      assert query_params["identity_provider_identifier"] == "user@example.com"
      assert query_params["account_name"] == account.name
      assert query_params["account_slug"] == account.slug
    end

    test "instructs user to restart sign in when cookie not present", %{
      conn: conn,
      account: account
    } do
      conn = get(conn, ~p"/#{account}/sign_in/client_redirect")
      redirect_path = redirected_to(conn, 302)
      assert redirect_path =~ ~p"/#{account}/sign_in/client_auth_error"

      query =
        redirect_path
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert query["error"] == "Please close this window and start the sign in process again."
    end

    test "displays account name on client auth error page", %{conn: conn, account: account} do
      conn = get(conn, ~p"/#{account}/sign_in/client_auth_error")
      assert html_response(conn, 200) =~ account.name
    end

    test "displays the error and retry link with params preserved", %{
      conn: conn,
      account: account
    } do
      conn =
        get(
          conn,
          ~p"/#{account}/sign_in/client_auth_error?#{%{"as" => "client", "state" => "retry-state", "nonce" => "retry-nonce", "error" => "The authorization code has expired or was already used. Please try signing in again."}}"
        )

      html = html_response(conn, 200)

      assert html =~
               "The authorization code has expired or was already used. Please try signing in again."

      [retry_path] =
        Regex.run(
          ~r/<a href="([^"]+)"[^>]*>\s*Return to sign in\s*<\/a>/s,
          html,
          capture: :all_but_first
        )

      query =
        retry_path
        |> String.replace("&amp;", "&")
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert String.starts_with?(retry_path, ~s(/#{account.slug}/sign_in?))
      assert query["as"] == "client"
      assert query["state"] == "retry-state"
      assert query["nonce"] == "retry-nonce"
    end
  end
end
