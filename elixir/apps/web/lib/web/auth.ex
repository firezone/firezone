defmodule Web.Auth do
  use Web, :verified_routes
  require Logger

  # This cookie is used for client login.
  @client_auth_cookie_name "client_auth"
  @client_auth_cookie_options [
    encrypt: true,
    max_age: 2 * 60,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  # This is the cookie which will store recent account ids
  # that the user has signed in to.
  @recent_accounts_cookie_name "recents"
  @max_cookie_age 60 * 60 * 24 * 400
  @recent_accounts_cookie_options [
    encrypt: true,
    max_age: @max_cookie_age,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]
  @remember_last_account_ids 50

  ###########################
  ## Controller Helpers
  ###########################

  def recent_account_ids(conn) do
    conn = Plug.Conn.fetch_cookies(conn, encrypted: [@recent_accounts_cookie_name])
    Map.get(conn.cookies, @recent_accounts_cookie_name, [])
  end

  def prepend_recent_account_id(conn, id_to_prepend) do
    recent = recent_account_ids(conn)
    ids = [id_to_prepend | recent] |> Enum.uniq() |> Enum.take(@remember_last_account_ids)

    Plug.Conn.put_resp_cookie(
      conn,
      @recent_accounts_cookie_name,
      ids,
      @recent_accounts_cookie_options
    )
  end

  def remove_recent_account_ids(conn, ids_to_remove) do
    recent = recent_account_ids(conn)
    ids = Enum.reject(recent, fn id -> id in ids_to_remove end)

    Plug.Conn.put_resp_cookie(
      conn,
      @recent_accounts_cookie_name,
      ids,
      @recent_accounts_cookie_options
    )
  end

  def get_client_auth_data_from_cookie(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_cookies(conn, encrypted: [@client_auth_cookie_name])

    case conn.cookies[@client_auth_cookie_name] do
      %{actor_name: _, fragment: _, identity_provider_identifier: _, state: _} = client_auth_data ->
        {:ok, client_auth_data, conn}

      _ ->
        {:error, conn}
    end
  end

  def put_client_auth_data_to_cookie(conn, state) do
    Plug.Conn.put_resp_cookie(conn, @client_auth_cookie_name, state, @client_auth_cookie_options)
  end

  @doc """
  Returns the real IP address of the client.
  """
  def real_ip(socket) do
    peer_data = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers)

    real_ip =
      if is_list(x_headers) and length(x_headers) > 0 do
        RemoteIp.from(x_headers, Web.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
  end

  @doc """
  Returns non-empty parameters that should be persisted during sign in flow.
  """
  def take_sign_in_params(params) do
    params
    |> Map.take(["as", "state", "nonce", "redirect_to"])
    |> Map.reject(fn {_key, value} -> value in ["", nil] end)
  end
end
