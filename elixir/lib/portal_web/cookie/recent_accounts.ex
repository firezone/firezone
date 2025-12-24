defmodule PortalWeb.Cookie.RecentAccounts do
  @moduledoc """
  Cookie for storing recent account IDs the user has signed into.
  """

  @enforce_keys [:account_ids]
  defstruct [:account_ids]

  @type t :: %__MODULE__{
          account_ids: [Ecto.UUID.t()]
        }

  @cookie_key "recent_accounts"
  @max_cookie_age 60 * 60 * 24 * 400
  @cookie_options [
    sign: true,
    max_age: @max_cookie_age,
    same_site: "Lax",
    secure: Portal.Config.fetch_env!(:web, :cookie_secure),
    http_only: true,
    signing_salt: Portal.Config.fetch_env!(:web, :cookie_signing_salt)
  ]
  @remember_last_accounts 10

  def put(conn, %__MODULE__{} = cookie) do
    Plug.Conn.put_resp_cookie(conn, @cookie_key, to_binary(cookie), @cookie_options)
  end

  def fetch(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@cookie_key])
    from_binary(conn.cookies[@cookie_key]) || %__MODULE__{account_ids: []}
  end

  def prepend(conn, account_id) do
    %__MODULE__{account_ids: ids} = fetch(conn)
    ids = [account_id | ids] |> Enum.uniq() |> Enum.take(@remember_last_accounts)
    put(conn, %__MODULE__{account_ids: ids})
  end

  def remove(conn, ids_to_remove) do
    %__MODULE__{account_ids: ids} = fetch(conn)
    ids = Enum.reject(ids, fn id -> id in ids_to_remove end)
    put(conn, %__MODULE__{account_ids: ids})
  end

  defp to_binary(%__MODULE__{account_ids: account_ids}) do
    account_ids
    |> Enum.map(&Ecto.UUID.dump!/1)
    |> :erlang.term_to_binary()
  end

  defp from_binary(binary) when is_binary(binary) do
    account_ids =
      binary
      |> :erlang.binary_to_term([:safe])
      |> Enum.map(&Ecto.UUID.load!/1)

    %__MODULE__{account_ids: account_ids}
  rescue
    _ -> nil
  end

  defp from_binary(_), do: nil
end
