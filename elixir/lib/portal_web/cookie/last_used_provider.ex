defmodule PortalWeb.Cookie.LastUsedProvider do
  @moduledoc """
  Cookie that remembers the ID of the auth provider used for the most recent
  successful sign in, so the sign in page can highlight it.
  """

  @cookie_key "last_used_provider"
  @max_cookie_age 60 * 60 * 24 * 400
  @cookie_options [
    sign: true,
    max_age: @max_cookie_age,
    same_site: "Lax",
    secure: Portal.Config.fetch_env!(:portal, :cookie_secure),
    http_only: true,
    signing_salt: Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
  ]

  def put(conn, provider_id) when is_binary(provider_id) do
    Plug.Conn.put_resp_cookie(conn, @cookie_key, provider_id, @cookie_options)
  end

  def fetch(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@cookie_key])

    case Ecto.UUID.cast(conn.cookies[@cookie_key]) do
      {:ok, provider_id} -> provider_id
      :error -> nil
    end
  end

  @doc """
  Used as a session function for the sign in live_session.
  """
  def fetch_state(conn) do
    %{"last_used_provider_id" => fetch(conn)}
  end
end
