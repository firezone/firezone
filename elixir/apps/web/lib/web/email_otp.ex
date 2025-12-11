defmodule Web.EmailOTP do
  @moduledoc """
  Helpers for email OTP authentication state management.
  """

  @cookie_key_prefix "email_otp_"
  @cookie_options [
    encrypt: true,
    max_age: 15 * 60,
    same_site: "Strict",
    secure: true,
    http_only: true
  ]

  def put_state(conn, provider_id, actor_id, passcode_id, email) do
    key = cookie_key(provider_id)
    value = %{"actor_id" => actor_id, "one_time_passcode_id" => passcode_id, "email" => email}
    Plug.Conn.put_resp_cookie(conn, key, value, @cookie_options)
  end

  def delete_state(conn, provider_id) do
    key = cookie_key(provider_id)
    Plug.Conn.delete_resp_cookie(conn, key)
  end

  @doc """
  Fetches email OTP state from the encrypted cookie.
  Used as a session function for the email_otp_verify live_session.
  """
  def fetch_state(%{path_params: %{"auth_provider_id" => provider_id}} = conn) do
    key = cookie_key(provider_id)
    conn = Plug.Conn.fetch_cookies(conn, encrypted: [key])
    conn.cookies[key] || %{}
  end

  def fetch_state(_conn), do: %{}

  defp cookie_key(provider_id) do
    @cookie_key_prefix <> provider_id
  end
end
