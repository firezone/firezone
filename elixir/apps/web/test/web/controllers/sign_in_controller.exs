defmodule Web.SignInControllerTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    account = Fixtures.Accounts.create_account()

    {:ok, account: account}
  end

  describe "success/2" do
    test "renders success page on proper cookie values", %{conn: conn} do
      provider = Fixtures.Auth.create_email_provider(account: account)
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      conn_with_cookies =
        conn
        |> put_client_auth_state(account, provider, identity)
        |> get(~p"/#{account}/sign_in/success")

      html = response(conn_with_cookies, 200)

      assert html =~ "Sign in successful"
      assert html =~ "close this window"
    end

    test "redirects to sign in page when cookie not present", %{account: account} do
      conn =
        build_conn()
        |> get(~p"/#{account}/sign_in/success")

      assert redirected_to(conn, 302) =~ ~p"/#{account}"
    end
  end
end
