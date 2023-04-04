defmodule Web.OIDC.State do
  @moduledoc """
  Helpers to manage the OIDC CSRF token, otherwise known as the state param,
  throughout the login flow.
  """
  @oidc_state_key "fz_oidc_state"
  @oidc_state_valid_duration 300

  import Plug.Conn

  def put_cookie(conn, state) do
    put_resp_cookie(conn, @oidc_state_key, state, cookie_opts())
  end

  def verify_state(conn, state) do
    conn
    |> fetch_cookies(signed: [@oidc_state_key])
    |> then(fn
      %{cookies: %{@oidc_state_key => ^state}} ->
        :ok

      _ ->
        {:error, "Cannot verify state"}
    end)
  end

  def new do
    Domain.Crypto.rand_string()
  end

  defp cookie_opts do
    [
      max_age: @oidc_state_valid_duration,
      sign: true,
      same_site: "Lax",
      secure: Domain.Config.fetch_env!(:web, :cookie_secure)
    ]
  end
end
