defmodule Web.Plugs.RedirectIfAuthenticatedTest do
  use Web.ConnCase, async: true

  import Domain.AccountFixtures
  import Domain.ActorFixtures

  alias Web.Plugs.RedirectIfAuthenticated

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    {:ok, account: account, actor: actor}
  end

  describe "call/2" do
    test "redirects authenticated user to portal when not signing in as client", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> Map.put(:params, %{})
        |> RedirectIfAuthenticated.call([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/#{account.slug}/sites"
    end

    test "does not redirect authenticated user when as=client param is set", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> Map.put(:params, %{"as" => "client"})
        |> RedirectIfAuthenticated.call([])

      refute conn.halted
    end

    test "does not redirect unauthenticated user", %{
      conn: conn,
      account: account
    } do
      conn =
        conn
        |> Plug.Conn.assign(:account, account)
        |> Map.put(:params, %{})
        |> RedirectIfAuthenticated.call([])

      refute conn.halted
    end

    test "does not redirect when no account is assigned", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> RedirectIfAuthenticated.call([])

      refute conn.halted
    end
  end
end
