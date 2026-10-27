defmodule PortalWeb.Plugs.FetchAccountTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures

  alias PortalWeb.Plugs.FetchAccount

  setup do
    account = account_fixture()
    {:ok, account: account}
  end

  describe "call/2" do
    test "assigns the account for its current slug", %{conn: conn, account: account} do
      conn =
        conn
        |> Map.put(:path_info, [account.slug, "sites"])
        |> FetchAccount.call([])

      refute conn.halted
      assert conn.assigns.account.id == account.id
    end

    test "assigns the account for its id", %{conn: conn, account: account} do
      conn =
        conn
        |> Map.put(:path_info, [account.id, "sites"])
        |> FetchAccount.call([])

      refute conn.halted
      assert conn.assigns.account.id == account.id
    end

    test "redirects a GET for an old slug to the current slug", %{
      conn: conn,
      account: account
    } do
      old_slug = account.slug
      account = update_account(account, slug: "#{old_slug}_renamed")

      conn =
        conn
        |> Map.put(:path_info, [old_slug, "settings", "account"])
        |> Map.put(:query_string, "foo=bar")
        |> FetchAccount.call([])

      assert conn.halted
      assert conn.assigns.account.id == account.id
      assert redirected_to(conn) == "/#{account.slug}/settings/account?foo=bar"
    end

    test "keeps a POST for an old slug on its path", %{conn: conn, account: account} do
      old_slug = account.slug
      account = update_account(account, slug: "#{old_slug}_renamed")

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:path_info, [old_slug, "sign_out"])
        |> FetchAccount.call([])

      refute conn.halted
      assert conn.assigns.account.id == account.id
    end

    test "does not redirect a slug that only differs in case", %{conn: conn, account: account} do
      conn =
        conn
        |> Map.put(:path_info, [String.upcase(account.slug), "sites"])
        |> FetchAccount.call([])

      refute conn.halted
      assert conn.assigns.account.id == account.id
    end

    test "leaves the conn alone for an unknown slug", %{conn: conn} do
      conn =
        conn
        |> Map.put(:path_info, ["nope", "sites"])
        |> FetchAccount.call([])

      refute conn.halted
      refute Map.has_key?(conn.assigns, :account)
    end
  end
end
