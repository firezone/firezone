defmodule PortalWeb.Cookie.SessionTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Cookie.Session

  defp recycle_conn(conn, account_id) do
    cookie_key = "sess_#{account_id}"
    cookie_value = conn.resp_cookies[cookie_key].value

    build_conn()
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(cookie_key, cookie_value)
  end

  defp recycle_conn(conn, account_id_1, account_id_2) do
    cookie_key_1 = "sess_#{account_id_1}"
    cookie_key_2 = "sess_#{account_id_2}"
    cookie_value_1 = conn.resp_cookies[cookie_key_1].value
    cookie_value_2 = conn.resp_cookies[cookie_key_2].value

    build_conn()
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(cookie_key_1, cookie_value_1)
    |> Plug.Test.put_req_cookie(cookie_key_2, cookie_value_2)
  end

  describe "put/3 and fetch/2" do
    test "stores and retrieves session for an account", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      session_id = Ecto.UUID.generate()

      cookie = %Session{session_id: session_id}

      conn =
        conn
        |> Session.put(account_id, cookie)
        |> recycle_conn(account_id)

      result = Session.fetch(conn, account_id)

      assert %Session{} = result
      assert result.session_id == session_id
    end

    test "stores sessions for multiple accounts independently", %{conn: conn} do
      account_id_1 = Ecto.UUID.generate()
      account_id_2 = Ecto.UUID.generate()
      session_id_1 = Ecto.UUID.generate()
      session_id_2 = Ecto.UUID.generate()

      conn =
        conn
        |> Session.put(account_id_1, %Session{session_id: session_id_1})
        |> Session.put(account_id_2, %Session{session_id: session_id_2})
        |> recycle_conn(account_id_1, account_id_2)

      result_1 = Session.fetch(conn, account_id_1)
      result_2 = Session.fetch(conn, account_id_2)

      assert result_1.session_id == session_id_1
      assert result_2.session_id == session_id_2
    end

    test "returns nil when cookie is not present", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      assert Session.fetch(conn, account_id) == nil
    end
  end

  describe "delete/2" do
    test "removes the session cookie for an account", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      session_id = Ecto.UUID.generate()

      # First put the cookie and recycle
      conn =
        conn
        |> Session.put(account_id, %Session{session_id: session_id})
        |> recycle_conn(account_id)

      # Verify cookie is present
      assert Session.fetch(conn, account_id) != nil

      # Delete the cookie - after delete the cookie is marked for expiration
      conn = Session.delete(conn, account_id)
      assert conn.resp_cookies["sess_#{account_id}"].max_age == 0
    end

    test "only removes the specified account session", %{conn: conn} do
      account_id_1 = Ecto.UUID.generate()
      account_id_2 = Ecto.UUID.generate()
      session_id_1 = Ecto.UUID.generate()
      session_id_2 = Ecto.UUID.generate()

      # First put both cookies and recycle
      conn =
        conn
        |> Session.put(account_id_1, %Session{session_id: session_id_1})
        |> Session.put(account_id_2, %Session{session_id: session_id_2})
        |> recycle_conn(account_id_1, account_id_2)

      # Delete only account_1's session
      conn = Session.delete(conn, account_id_1)

      # account_1's cookie is marked for expiration
      assert conn.resp_cookies["sess_#{account_id_1}"].max_age == 0
      # account_2's session is still fetchable
      assert Session.fetch(conn, account_id_2).session_id == session_id_2
    end
  end
end
