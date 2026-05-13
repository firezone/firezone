defmodule PortalWeb.Cookie.PendingIdentityTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Cookie.PendingIdentity

  defp cookie_key(pending_identity_id), do: "pending_identity_#{pending_identity_id}"

  defp recycle_conn(conn, pending_identity_id) do
    key = cookie_key(pending_identity_id)
    cookie_value = conn.resp_cookies[key].value

    build_conn()
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(key, cookie_value)
    |> Map.put(:params, %{"pending_identity_id" => pending_identity_id})
  end

  describe "put/2 and fetch/1" do
    test "stores and retrieves only the pending identity id", %{conn: conn} do
      pending_identity_id = Ecto.UUID.generate()
      cookie = %PendingIdentity{pending_identity_id: pending_identity_id}

      conn =
        conn
        |> PendingIdentity.put(cookie)
        |> recycle_conn(pending_identity_id)

      assert %PendingIdentity{pending_identity_id: ^pending_identity_id} = PendingIdentity.fetch(conn)
    end

    test "returns nil when the requested id does not match the cookie name", %{conn: conn} do
      pending_identity_id = Ecto.UUID.generate()
      cookie = %PendingIdentity{pending_identity_id: pending_identity_id}

      conn =
        conn
        |> PendingIdentity.put(cookie)
        |> recycle_conn(pending_identity_id)
        |> Map.put(:params, %{"pending_identity_id" => Ecto.UUID.generate()})

      assert PendingIdentity.fetch(conn) == nil
    end

    test "returns nil when cookie is not present", %{conn: conn} do
      assert PendingIdentity.fetch(conn) == nil
    end
  end

  describe "fetch_state/1" do
    test "returns map format for live_session compatibility", %{conn: conn} do
      pending_identity_id = Ecto.UUID.generate()
      cookie = %PendingIdentity{pending_identity_id: pending_identity_id}

      conn =
        conn
        |> PendingIdentity.put(cookie)
        |> recycle_conn(pending_identity_id)

      assert PendingIdentity.fetch_state(conn) == %{
               "pending_identity_id" => pending_identity_id
             }
    end

    test "returns empty map when cookie is not present", %{conn: conn} do
      assert PendingIdentity.fetch_state(conn) == %{}
    end
  end

  describe "delete/1" do
    test "removes the cookie", %{conn: conn} do
      cookie = %PendingIdentity{pending_identity_id: Ecto.UUID.generate()}

      conn =
        conn
        |> PendingIdentity.put(cookie)
        |> recycle_conn(cookie.pending_identity_id)

      assert PendingIdentity.fetch(conn) != nil

      conn = PendingIdentity.delete(conn, cookie.pending_identity_id)
      assert conn.resp_cookies[cookie_key(cookie.pending_identity_id)].max_age == 0
    end
  end
end
