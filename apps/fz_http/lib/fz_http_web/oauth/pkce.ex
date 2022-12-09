defmodule FzHttpWeb.OAuth.PKCE do
  @moduledoc """
  Helpers related to PKCE for OAuth2.
  """

  @pkce_key "fz_pkce_code_verifier"
  @pkce_valid_duration 60
  @code_challenge_method :S256

  import Plug.Conn
  import Wrapped.Application

  def put_cookie(conn, verifier) do
    put_resp_cookie(conn, @pkce_key, verifier, cookie_opts())
  end

  def token_params(conn) do
    conn
    |> fetch_cookies(signed: [@pkce_key])
    |> then(fn
      %{cookies: %{@pkce_key => verifier}} ->
        %{code_verifier: verifier}

      _ ->
        %{}
    end)
  end

  def code_challenge_method do
    @code_challenge_method
  end

  def code_verifier do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  def code_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp cookie_opts do
    [
      max_age: @pkce_valid_duration,
      sign: true,
      same_site: "Lax",
      secure: app().fetch_env!(:fz_http, :cookie_secure)
    ]
  end
end
