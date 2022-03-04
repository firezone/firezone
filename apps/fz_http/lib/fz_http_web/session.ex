defmodule FzHttpWeb.Session do
  @moduledoc """
  Dynamically configures session.
  """

  @max_cookie_age 604_800

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_fz_http_key",
    # XXX: Strict doesn't work for SSO auth
    # same_site: "Strict",
    max_age: @max_cookie_age,
    secure: true,
    sign: true,
    encrypt: true
  ]

  def options do
    @session_options ++ [signing_salt: signing_salt()]
  end

  defp signing_salt do
    Application.fetch_env!(:fz_http, :cookie_signing_salt)
  end
end
