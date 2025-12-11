defmodule Web.EmailOTPTest do
  use Web.ConnCase, async: true

  alias Web.EmailOTP

  describe "put_state/5" do
    test "sets encrypted cookie with correct options", %{conn: conn} do
      provider_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()
      passcode_id = Ecto.UUID.generate()
      email = "test@example.com"

      conn = EmailOTP.put_state(conn, provider_id, actor_id, passcode_id, email)

      cookie_key = "email_otp_#{provider_id}"
      assert %{^cookie_key => cookie} = conn.resp_cookies

      assert cookie.max_age == 15 * 60
      assert cookie.same_site == "Strict"
      assert cookie.secure == true
      assert cookie.http_only == true
    end
  end

  describe "delete_state/2" do
    test "deletes the cookie for the provider", %{conn: conn} do
      provider_id = Ecto.UUID.generate()

      conn = EmailOTP.delete_state(conn, provider_id)

      cookie_key = "email_otp_#{provider_id}"
      assert %{^cookie_key => cookie} = conn.resp_cookies
      assert cookie.max_age == 0
    end
  end

  describe "fetch_state/1" do
    test "returns state from cookie when provider_id is in path_params", %{conn: conn} do
      provider_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()
      passcode_id = Ecto.UUID.generate()
      email = "test@example.com"

      cookie_key = "email_otp_#{provider_id}"

      conn =
        conn
        |> EmailOTP.put_state(provider_id, actor_id, passcode_id, email)
        |> Plug.Conn.send_resp(200, "")
        |> then(&Plug.Test.recycle_cookies(build_conn(), &1))
        |> Map.put(:path_params, %{"auth_provider_id" => provider_id})
        |> Map.put(:secret_key_base, Web.Endpoint.config(:secret_key_base))
        |> Plug.Conn.fetch_cookies(encrypted: [cookie_key])

      assert EmailOTP.fetch_state(conn) == %{
               "actor_id" => actor_id,
               "one_time_passcode_id" => passcode_id,
               "email" => email
             }
    end

    test "returns empty map when provider_id is not in path_params", %{conn: conn} do
      conn = Map.put(conn, :path_params, %{})
      assert EmailOTP.fetch_state(conn) == %{}
    end

    test "returns empty map when cookie is not present", %{conn: conn} do
      provider_id = Ecto.UUID.generate()
      conn = Map.put(conn, :path_params, %{"auth_provider_id" => provider_id})
      assert EmailOTP.fetch_state(conn) == %{}
    end
  end
end
