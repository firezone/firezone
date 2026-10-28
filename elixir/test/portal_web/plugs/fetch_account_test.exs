defmodule PortalWeb.Plugs.FetchAccountTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures

  alias PortalWeb.Plugs.FetchAccount

  setup do
    account = account_fixture()
    {:ok, account: account}
  end

  describe "call/2 with the shared slug registry" do
    import Plug.Conn
    import Portal.SlugRegistryHelpers

    setup do
      use_azure_registry(:us)
      :ok
    end

    test "sends a GET for a slug another region holds to that region", %{conn: conn} do
      stub_registry(fn
        %{method: "GET"} = conn -> Req.Test.json(conn, entity("eu-acme", Ecto.UUID.generate(), "eu"))
      end)

      conn =
        conn
        |> Map.put(:path_info, ["eu-acme", "sites"])
        |> Map.put(:query_string, "page=2")
        |> FetchAccount.call([])

      assert conn.halted
      assert redirected_to(conn) == "https://eu.app.firezone.dev/eu-acme/sites?page=2"
    end

    test "keeps going for a slug nobody holds", %{conn: conn} do
      stub_registry(fn _conn -> :default end)

      conn = conn |> Map.put(:path_info, ["nobody-#{System.unique_integer([:positive])}", "sites"]) |> FetchAccount.call([])

      refute conn.halted
      refute Map.has_key?(conn.assigns, :account)
    end

    test "keeps going and logs when the registry is unavailable", %{conn: conn} do
      stub_registry(fn conn -> send_resp(conn, 503, "") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = conn |> Map.put(:path_info, ["down-#{System.unique_integer([:positive])}", "sites"]) |> FetchAccount.call([])
          refute conn.halted
        end)

      assert log =~ "Slug registry request failed"
    end

    test "does not redirect a POST", %{conn: conn} do
      stub_registry(fn _conn -> flunk("must not look up the registry") end)

      conn = conn |> Map.put(:method, "POST") |> Map.put(:path_info, ["eu-acme", "sites"]) |> FetchAccount.call([])

      refute conn.halted
    end
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

    test "redirects the underscore twin of a hyphenated slug to the current slug", %{
      conn: conn,
      account: account
    } do
      account = update_account(account, slug: "acme-corp")

      conn =
        conn
        |> Map.put(:path_info, ["acme_corp", "sign_in"])
        |> FetchAccount.call([])

      assert conn.halted
      assert conn.assigns.account.id == account.id
      assert redirected_to(conn) == "/acme-corp/sign_in"
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
