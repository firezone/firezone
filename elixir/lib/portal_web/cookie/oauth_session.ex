defmodule PortalWeb.Cookie.OAuthSession do
  @moduledoc """
  Cookie holding the session used to approve an app connection.

  Deliberately separate from `PortalWeb.Cookie.Session`, under its own name
  `oauth_sess_<account_id>`, so the two directions stay independent: approving a
  connection does not sign the person into the portal, and an existing portal
  session does not carry them through the approval. Whoever grants access has to
  authenticate for that grant.

  It is short lived because it exists only to get through one flow.
  """

  @enforce_keys [:session_id]
  defstruct [:session_id]

  @type t :: %__MODULE__{
          session_id: Ecto.UUID.t()
        }

  @lifetime_secs 15 * 60

  @doc """
  How long the cookie and the session behind it are good for.

  Used for both, so the browser and the database agree on when the flow expires.
  """
  def lifetime_secs, do: @lifetime_secs

  def put(conn, account_id, %__MODULE__{session_id: session_id}) do
    Plug.Conn.put_resp_cookie(
      conn,
      cookie_name(account_id),
      Ecto.UUID.dump!(session_id),
      cookie_options()
    )
  end

  def fetch(conn, account_id) do
    cookie_name = cookie_name(account_id)
    conn = Plug.Conn.fetch_cookies(conn, signed: [cookie_name])

    case Map.get(conn.cookies, cookie_name) do
      <<_::128>> = binary -> %__MODULE__{session_id: Ecto.UUID.load!(binary)}
      _ -> nil
    end
  end

  def delete(conn, account_id) do
    Plug.Conn.delete_resp_cookie(conn, cookie_name(account_id), cookie_options())
  end

  defp cookie_name(account_id) when is_binary(account_id) do
    "oauth_sess_#{account_id}"
  end

  defp cookie_options do
    [
      sign: true,
      max_age: @lifetime_secs,
      same_site: "Lax",
      secure: Portal.Config.fetch_env!(:portal, :cookie_secure),
      http_only: true,
      signing_salt: Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
    ]
  end
end
