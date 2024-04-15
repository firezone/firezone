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
        |> put_client_auth_state(account, provider, identity)
        |> get(~p"/#{account}/sign_in/client_redirect")

      assert redirected = redirected_to(conn_with_cookies, 302)
      assert redirected =~ "firezone-fd0020211111://handle_client_sign_in_callback"
    end

    test "redirects to sign in page when cookie not present", %{account: account} do
      conn =
        build_conn()
        |> get(~p"/#{account}/sign_in/client_redirect")

      assert redirected_to(conn, 302) =~ ~p"/#{account}/sign_in/client_auth_error"
    end
  end
end
