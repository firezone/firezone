defmodule PortalWeb.Cookie.RecentAccountsTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Cookie.RecentAccounts

  @cookie_key "recent_accounts"

  defp recycle_conn(conn) do
    cookie_value = conn.resp_cookies[@cookie_key].value

    build_conn()
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(@cookie_key, cookie_value)
  end

  describe "put/2 and fetch/1" do
    test "stores and retrieves account ids", %{conn: conn} do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      cookie = %RecentAccounts{account_ids: [id1, id2]}

      conn =
        conn
        |> RecentAccounts.put(cookie)
        |> recycle_conn()

      result = RecentAccounts.fetch(conn)

      assert %RecentAccounts{} = result
      assert result.account_ids == [id1, id2]
    end

    test "returns empty list when cookie is not present", %{conn: conn} do
      result = RecentAccounts.fetch(conn)
      assert result == %RecentAccounts{account_ids: []}
    end
  end

  describe "prepend/2" do
    test "adds account id to the front", %{conn: conn} do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      conn =
        conn
        |> RecentAccounts.prepend(id1)
        |> recycle_conn()
        |> RecentAccounts.prepend(id2)
        |> recycle_conn()

      result = RecentAccounts.fetch(conn)
      assert result.account_ids == [id2, id1]
    end

    test "deduplicates account ids", %{conn: conn} do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      conn =
        conn
        |> RecentAccounts.prepend(id1)
        |> recycle_conn()
        |> RecentAccounts.prepend(id2)
        |> recycle_conn()
        |> RecentAccounts.prepend(id1)
        |> recycle_conn()

      result = RecentAccounts.fetch(conn)
      assert result.account_ids == [id1, id2]
    end

    test "limits to 10 accounts", %{conn: conn} do
      ids = Enum.map(1..15, fn _ -> Ecto.UUID.generate() end)

      conn =
        Enum.reduce(ids, conn, fn id, conn ->
          conn
          |> RecentAccounts.prepend(id)
          |> recycle_conn()
        end)

      result = RecentAccounts.fetch(conn)
      assert length(result.account_ids) == 10
      assert result.account_ids == Enum.take(Enum.reverse(ids), 10)
    end
  end

  describe "remove/2" do
    test "removes specified account ids", %{conn: conn} do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()
      id3 = Ecto.UUID.generate()

      cookie = %RecentAccounts{account_ids: [id1, id2, id3]}

      conn =
        conn
        |> RecentAccounts.put(cookie)
        |> recycle_conn()
        |> RecentAccounts.remove([id2])
        |> recycle_conn()

      result = RecentAccounts.fetch(conn)
      assert result.account_ids == [id1, id3]
    end

    test "removes multiple account ids", %{conn: conn} do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()
      id3 = Ecto.UUID.generate()

      cookie = %RecentAccounts{account_ids: [id1, id2, id3]}

      conn =
        conn
        |> RecentAccounts.put(cookie)
        |> recycle_conn()
        |> RecentAccounts.remove([id1, id3])
        |> recycle_conn()

      result = RecentAccounts.fetch(conn)
      assert result.account_ids == [id2]
    end

    test "handles removing non-existent ids gracefully", %{conn: conn} do
      id1 = Ecto.UUID.generate()
      non_existent = Ecto.UUID.generate()

      cookie = %RecentAccounts{account_ids: [id1]}

      conn =
        conn
        |> RecentAccounts.put(cookie)
        |> recycle_conn()
        |> RecentAccounts.remove([non_existent])
        |> recycle_conn()

      result = RecentAccounts.fetch(conn)
      assert result.account_ids == [id1]
    end
  end
end
