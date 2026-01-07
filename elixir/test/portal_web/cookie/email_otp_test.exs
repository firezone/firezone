defmodule PortalWeb.Cookie.EmailOTPTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Cookie.EmailOTP

  @cookie_key "email_otp"

  defp recycle_conn(conn) do
    cookie_value = conn.resp_cookies[@cookie_key].value

    build_conn()
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(@cookie_key, cookie_value)
  end

  describe "put/2 and fetch/1" do
    test "stores and retrieves cookie data", %{conn: conn} do
      actor_id = Ecto.UUID.generate()
      passcode_id = Ecto.UUID.generate()
      email = "test@example.com"

      cookie = %EmailOTP{
        actor_id: actor_id,
        passcode_id: passcode_id,
        email: email
      }

      conn =
        conn
        |> EmailOTP.put(cookie)
        |> recycle_conn()

      result = EmailOTP.fetch(conn)

      assert %EmailOTP{} = result
      assert result.actor_id == actor_id
      assert result.passcode_id == passcode_id
      assert result.email == email
    end

    test "returns nil when cookie is not present", %{conn: conn} do
      assert EmailOTP.fetch(conn) == nil
    end
  end

  describe "fetch_state/1" do
    test "returns map format for live_session compatibility", %{conn: conn} do
      actor_id = Ecto.UUID.generate()
      passcode_id = Ecto.UUID.generate()
      email = "test@example.com"

      cookie = %EmailOTP{
        actor_id: actor_id,
        passcode_id: passcode_id,
        email: email
      }

      conn =
        conn
        |> EmailOTP.put(cookie)
        |> recycle_conn()

      result = EmailOTP.fetch_state(conn)

      assert result == %{
               "actor_id" => actor_id,
               "one_time_passcode_id" => passcode_id,
               "email" => email
             }
    end

    test "returns empty map when cookie is not present", %{conn: conn} do
      assert EmailOTP.fetch_state(conn) == %{}
    end
  end

  describe "delete/1" do
    test "removes the cookie", %{conn: conn} do
      cookie = %EmailOTP{
        actor_id: Ecto.UUID.generate(),
        passcode_id: Ecto.UUID.generate(),
        email: "test@example.com"
      }

      # First put the cookie and recycle
      conn =
        conn
        |> EmailOTP.put(cookie)
        |> recycle_conn()

      # Verify cookie is present
      assert EmailOTP.fetch(conn) != nil

      # Delete the cookie - after delete the cookie is marked for expiration
      conn = EmailOTP.delete(conn)
      assert conn.resp_cookies[@cookie_key].max_age == 0
    end
  end
end
