defmodule Web.Session do
  @moduledoc """
  Dynamically configures session.
  """

  # 4 hours
  @max_cookie_age 14_400

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_firezone_key",
    # XXX: Strict doesn't work for SSO auth
    # same_site: "Strict",
    max_age: @max_cookie_age,
    sign: true,
    encrypt: true
  ]

  def options do
    @session_options ++
      [secure: cookie_secure(), signing_salt: signing_salt(), encryption_salt: encryption_salt()]
  end

  defp cookie_secure do
    Domain.Config.fetch_env!(:web, :cookie_secure)
  end

  defp signing_salt do
    [vsn | _] =
      Application.spec(:domain, :vsn)
      |> to_string()
      |> String.split("+")

    Domain.Config.fetch_env!(:web, :cookie_signing_salt) <> vsn
  end

  defp encryption_salt do
    Domain.Config.fetch_env!(:web, :cookie_encryption_salt)
  end
end
