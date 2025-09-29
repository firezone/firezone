defmodule Web.Session.Cookie do
  @moduledoc """
  Handles per-account session cookies for the new auth system.

  For migrated accounts, this module manages individual session cookies
  named `_sess_<account_id>` that store the session token and logout URI.
  """

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
  def put_account_cookie(conn, account_id, token) do
    cookie_name = cookie_name(account_id)

    # Extract token_id from the encoded fragment to generate the live_socket_id
    # The token is already encoded, we need to get the token_id
    # For now, we'll compute it when fetching the subject
    cookie_data = %{"token" => token}

    Plug.Conn.put_resp_cookie(conn, cookie_name, cookie_data, cookie_options())
  end

  @doc """
  Fetches account session data from a per-account cookie.
  Returns `{:ok, token}` or `:error`.
  """
  def fetch_account_cookie(conn, account_id) do
    cookie_name = cookie_name(account_id)
    conn = Plug.Conn.fetch_cookies(conn, signed: [cookie_name], encrypted: [cookie_name])

    case Map.get(conn.cookies, cookie_name) do
      %{"token" => token} ->
        {:ok, token}

      _ ->
        :error
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

  @doc """
  Mounts the subject for LiveView sockets (migrated accounts only).
  Reads the per-account cookie from connect_info and authenticates.
  """
  def mount_subject(socket, params, _session) do
    Phoenix.Component.assign_new(socket, :subject, fn ->
      params = Web.Auth.take_sign_in_params(params)
      context_type = Web.Auth.fetch_auth_context_type!(params)
      user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
      real_ip = Web.Auth.real_ip(socket)
      x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
      context = Domain.Auth.Context.build(real_ip, user_agent, x_headers, context_type)

      with account when not is_nil(account) <- Map.get(socket.assigns, :account),
           {:ok, encoded_fragment} <- fetch_token_from_socket(socket, account.id),
           {:ok, subject} <- Domain.Auth.authenticate(encoded_fragment, context),
           true <- subject.account.id == account.id do
        subject
      else
        _ -> nil
      end
    end)
  end

  # Fetches the token from the per-account cookie in LiveView connect_info
  defp fetch_token_from_socket(socket, account_id) do
    cookie_name = cookie_name(account_id)
    account_cookies = Phoenix.LiveView.get_connect_info(socket, :account_cookies) || %{}

    # The account_cookies map is already decrypted by Plug.Conn.fetch_cookies
    # in the Web.LiveView.AccountCookies handler
    case Map.get(account_cookies, cookie_name) do
      %{"token" => token} -> {:ok, token}
      _ -> :error
    end
  end

  @doc """
  Fetches the session token from the per-account cookie and assigns the subject to the connection.
  This is for the new auth system (migrated accounts only).

  Note: We do NOT store live_socket_id in Plug.Session for the new system.
  The LiveView socket connection will need to derive the socket_id from the token_id directly.
  """
  def fetch_subject(%Plug.Conn{} = conn, _opts) do
    params = Web.Auth.take_sign_in_params(conn.params)
    context_type = Web.Auth.fetch_auth_context_type!(params)
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    context = Domain.Auth.Context.build(remote_ip, user_agent, conn.req_headers, context_type)

    if account = Map.get(conn.assigns, :account) do
      with {:ok, encoded_fragment} <- fetch_account_cookie(conn, account.id),
           {:ok, subject} <- Domain.Auth.authenticate(encoded_fragment, context),
           true <- subject.account.id == account.id do
        # For the new system, we don't store live_socket_id in the session
        # Instead, LiveView will need to compute it from the subject.token_id
        Plug.Conn.assign(conn, :subject, subject)
      else
        {:error, :unauthorized} ->
          delete_account_cookie(conn, account.id)

        _ ->
          conn
      end
    else
      conn
    end
  end
end
