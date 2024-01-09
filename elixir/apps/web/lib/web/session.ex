defmodule Web.Session do
  @moduledoc """
  We wrap Plug.Session because it's options are resolved at compile-time,
  which doesn't work with Elixir releases and runtime configuration.
  """
  @behaviour Plug

  # 4 hours
  @max_cookie_age 4 * 60 * 60

  # The session will be stored in the cookie signed and encrypted for 4 hours
  @session_options [
    store: :cookie,
    key: "_firezone_key",
    # If `same_site` is set to `Strict` then the cookie will not be sent on
    # IdP callback redirects, which will break the auth flow.
    same_site: "Lax",
    max_age: @max_cookie_age,
    sign: true,
    encrypt: true
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    opts = options() |> Plug.Session.init()
    Plug.Session.call(conn, opts)
  end

  @doc false
  def options do
    @session_options ++
      [
        secure: cookie_secure(),
        signing_salt: signing_salt(),
        encryption_salt: encryption_salt()
      ]
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
