defmodule Web.Cookie.Session do
  @moduledoc """
  Cookie for storing session ID for an account.
  Uses per-account cookie names: `sess_<account_id>`.
  """

  @enforce_keys [:session_id]
  defstruct [:session_id]

  @type t :: %__MODULE__{
          session_id: Ecto.UUID.t()
        }

  # Full work day - 8 hours
  @max_cookie_age 8 * 60 * 60

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
    "sess_#{account_id}"
  end

  defp cookie_options do
    [
      sign: true,
      max_age: @max_cookie_age,
      same_site: "Lax",
      secure: Domain.Config.fetch_env!(:web, :cookie_secure),
      http_only: true,
      signing_salt: Domain.Config.fetch_env!(:web, :cookie_signing_salt)
    ]
  end
end
