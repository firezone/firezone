defmodule Web.Session do
  @moduledoc """
  We wrap Plug.Session because it's options are resolved at compile-time,
  which doesn't work with Elixir releases and runtime configuration.
  """
  @behaviour Plug

  # 4 hours
  @max_cookie_age 14_400

  # The session will be stored in the cookie signed and encrypted for 4 hours
  @session_options [
    store: :cookie,
    key: "_firezone_key",
    # XXX: Strict doesn't work for SSO auth
    # same_site: "Strict",
    max_age: @max_cookie_age,
    sign: true,
    encrypt: true
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    opts = options() |> Plug.Session.init()

    conn
    |> Plug.Session.call(opts)
    |> put_context_assigns()
  end

  defp put_context_assigns(conn) do
    remote_ip = get_remote_ip(conn)
    user_agent = get_user_agent(conn)

    conn
    |> Plug.Conn.assign(:remote_ip, remote_ip)
    |> Plug.Conn.assign(:user_agent, user_agent)
  end

  defp get_remote_ip(conn) do
    conn.remote_ip
  end

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [user_agent | _] ->
        user_agent

      _ ->
        nil
    end
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
