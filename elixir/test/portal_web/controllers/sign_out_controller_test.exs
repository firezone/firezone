defmodule PortalWeb.SignOutControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    provider = userpass_provider_fixture(account: account)
    %{account: account, actor: actor, provider: provider}
  end

  describe "sign_out/2" do
    test "ends the portal session and the app approval session", %{
      conn: conn,
      account: account,
      actor: actor,
      provider: provider
    } do
      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> authorize_conn_with_provider(actor, provider)
        |> post(~p"/#{account.id}/sign_out")

      assert redirected_to(conn) =~ "/#{account.id}"
      assert conn.resp_cookies["sess_#{account.id}"].max_age == 0
      assert conn.resp_cookies["oauth_sess_#{account.id}"].max_age == 0
      assert Portal.Repo.all(Portal.PortalSession) == []

      conn = conn |> recycle() |> get(~p"/#{account.slug}/oauth/authorize")
      assert redirected_to(conn) =~ "/sign_in"
    end

    test "ends the app approval session without a portal session", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> post(~p"/#{account.id}/sign_out")

      assert redirected_to(conn) == "/#{account.id}"
      assert conn.resp_cookies["oauth_sess_#{account.id}"].max_age == 0
      assert Portal.Repo.all(Portal.PortalSession) == []
    end

    test "keeps app approval sessions of other browsers", %{
      conn: conn,
      account: account,
      actor: actor,
      provider: provider
    } do
      authorize_oauth_conn(conn, actor)

      conn =
        conn
        |> authorize_conn_with_provider(actor, provider)
        |> post(~p"/#{account.id}/sign_out")

      refute Map.has_key?(conn.resp_cookies, "oauth_sess_#{account.id}")
      assert [%Portal.PortalSession{}] = Portal.Repo.all(Portal.PortalSession)
    end
  end
end
