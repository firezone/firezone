defmodule Web.Session.Cookie do
  @moduledoc """
  This module manages individual session cookies named `_sess_<account_id>` that store the session token.
  """

  require Logger

  # Full work day - 8 hours
  @max_cookie_age 8 * 60 * 60

  @doc """
  Returns the cookie name for a given account.
  """
  def cookie_name(account_id) when is_binary(account_id) do
    "_sess_#{account_id}"
  end

  @doc """
  Returns the cookie options for account session cookies.
  """
  def cookie_options do
    [
      encrypt: true,
      max_age: @max_cookie_age,
      same_site: "Lax",
      secure: cookie_secure(),
      http_only: true,
      signing_salt: signing_salt(),
      encryption_salt: encryption_salt()
    ]
  end

  @doc """
  Puts account session data into a per-account cookie.
  """
  def put_account_cookie(conn, account_id, session_id) do
    cookie_name = cookie_name(account_id)
    cookie_data = %{"session_id" => session_id}

    Plug.Conn.put_resp_cookie(conn, cookie_name, cookie_data, cookie_options())
  end

  @doc """
  Fetches account session data from a per-account cookie.
  Returns `{:ok, session_id}` or `:error`.
  """
  def fetch_account_cookie(conn, account_id) do
    cookie_name = cookie_name(account_id)
    conn = Plug.Conn.fetch_cookies(conn, encrypted: [cookie_name])

    with {:ok, %{"session_id" => session_id}} <- Map.fetch(conn.cookies, cookie_name) do
      {:ok, session_id}
    end
  end

  @doc """
  Deletes the account session cookie.
  """
  def delete_account_cookie(conn, account_id) do
    cookie_name = cookie_name(account_id)
    Plug.Conn.delete_resp_cookie(conn, cookie_name, cookie_options())
  end

  defp cookie_secure do
    Domain.Config.fetch_env!(:web, :cookie_secure)
  end

  defp signing_salt do
    Domain.Config.fetch_env!(:web, :cookie_signing_salt)
  end

  defp encryption_salt do
    Domain.Config.fetch_env!(:web, :cookie_encryption_salt)
  end
end
