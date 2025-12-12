defmodule Web.SignInControllerTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    account = Fixtures.Accounts.create_account()

    {:ok, account: account}
  end

  describe "client_redirect/2" do
    test "renders 302 with deep link location on proper cookie values", %{
      conn: conn,
      account: account
    } do
      provider = Fixtures.Auth.create_email_provider(account: account)
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      conn_with_cookies =
        conn
        |> put_client_auth_state(account, provider, identity, %{
          "state" => "STATE",
          "nonce" => "NONCE"
        })
        |> get(~p"/#{account}/sign_in/client_redirect")

      assert redirected_to = redirected_to(conn_with_cookies, 302)
      assert redirected_to =~ "firezone-fd0020211111://handle_client_sign_in_callback"

      assert redirected_uri = URI.parse(redirected_to)
      assert query_params = URI.decode_query(redirected_uri.query)
      assert not is_nil(query_params["fragment"])
      refute query_params["fragment"] =~ "NONCE"
      assert query_params["state"] == "STATE"
      refute query_params["nonce"]
      assert query_params["actor_name"] == actor.name
      assert query_params["identity_provider_identifier"] == identity.provider_identifier
      assert query_params["account_name"] == account.name
      assert query_params["account_slug"] == account.slug
    end

    test "instructs user to restart sign in when cookie not present", %{account: account} do
      conn =
        build_conn()
        |> get(~p"/#{account}/sign_in/client_redirect")

      assert redirected_to(conn, 302) =~ ~p"/#{account}/sign_in/client_auth_error"
    end

    test "displays account name on client auth error page", %{account: account} do
      conn =
        build_conn()
        |> get(~p"/#{account}/sign_in/client_auth_error")

      assert html_response(conn, 200) =~ account.name
    end
  end
end
