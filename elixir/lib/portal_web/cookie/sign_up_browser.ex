defmodule PortalWeb.Cookie.SignUpBrowser do
  @moduledoc """
  Cookie that binds an email sign-up link to the browser that requested it.

  Sign-up pages give the browser a random id. The emailed token carries a hash of that id,
  and the link only creates the account and signs in from a browser holding the same id.
  Without this, anyone could request a link for their own email and send it to someone
  else, signing that person in to an account the sender controls.
  """

  @behaviour Plug

  import Plug.Conn

  @cookie_key "sign_up_browser"
  @session_key "sign_up_browser_id"
  @private_key :sign_up_browser_id
  # Outlives the 24-hour link requested after the cookie was last refreshed.
  @max_age 2 * 24 * 60 * 60

  @impl true
  def init(opts), do: opts

  # Refreshed on every sign-up page so the cookie outlives any link requested from it.
  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["sign_up" | _]} = conn, _opts), do: ensure(conn)
  def call(%Plug.Conn{method: "GET", path_info: ["try"]} = conn, _opts), do: ensure(conn)
  def call(conn, _opts), do: conn

  @doc """
  Returns the browser id for the `live_session` session, so the LiveView can bind and check links.
  """
  @spec live_session(Plug.Conn.t()) :: map()
  def live_session(conn) do
    %{@session_key => conn.private[@private_key] || fetch(conn)}
  end

  @spec from_session(map()) :: String.t() | nil
  def from_session(session), do: Map.get(session, @session_key)

  @spec fetch(Plug.Conn.t()) :: String.t() | nil
  def fetch(conn) do
    conn = fetch_cookies(conn, signed: [@cookie_key])

    case conn.cookies[@cookie_key] do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  @doc """
  Returns the value a sign-up token carries to identify the browser, without revealing the id.
  """
  @spec token_claim(String.t() | nil) :: String.t() | nil
  def token_claim(id) when is_binary(id), do: :crypto.hash(:sha256, id) |> Base.url_encode64(padding: false)
  def token_claim(nil), do: nil

  @spec bound?(term(), String.t() | nil) :: boolean()
  def bound?(claim, id) when is_binary(claim) and is_binary(id),
    do: Plug.Crypto.secure_compare(token_claim(id), claim)

  def bound?(_claim, _id), do: false

  defp ensure(conn) do
    id = fetch(conn) || generate_id()

    conn
    |> put_resp_cookie(@cookie_key, id, cookie_options())
    |> put_private(@private_key, id)
  end

  defp generate_id, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp cookie_options do
    [
      sign: true,
      max_age: @max_age,
      same_site: "Lax",
      secure: Portal.Config.fetch_env!(:portal, :cookie_secure),
      http_only: true,
      signing_salt: Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
    ]
  end
end
