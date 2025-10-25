defmodule Web.Auth do
  use Web, :verified_routes
  alias Domain.Auth
  alias Web.Session.Redirector
  require Logger

  # This cookie is used for client login.
  @client_auth_cookie_name "fz_client_auth"
  @client_auth_cookie_options [
    sign: true,
    max_age: 2 * 60,
    same_site: "Strict",
    secure: true,
    http_only: true
  ]

  # This is the cookie which will store recent account ids
  # that the user has signed in to.
  @recent_accounts_cookie_name "fz_recent_account_ids"
  @recent_accounts_cookie_options [
    sign: true,
    max_age: 365 * 24 * 60 * 60,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]
  @remember_last_account_ids 5

  # Session is stored as a list in a cookie so we want to limit numbers
  # of items in the list to avoid hitting cookie size limit.
  #
  # Max cookie size is 4kb. One session is ~460 bytes.
  # We also leave space for other cookies.
  @remember_last_sessions 6

  # Session Management

  def put_account_session(%Plug.Conn{} = conn, :client, _account_id, _encoded_fragment) do
    conn
  end

  def put_account_session(%Plug.Conn{} = conn, :browser, account_id, encoded_fragment) do
    session = {:browser, account_id, encoded_fragment}

    sessions =
      Plug.Conn.get_session(conn, :sessions, [])
      |> Enum.reject(fn {session_context_type, session_account_id, _encoded_fragment} ->
        session_context_type == :browser and session_account_id == account_id
      end)

    sessions = Enum.take(sessions ++ [session], -1 * @remember_last_sessions)

    conn
    |> renew_session()
    |> Plug.Conn.put_session(:sessions, sessions)
  end

  # Signing In and Out

  @doc """
  Returns non-empty parameters that should be persisted during sign in flow.
  """
  def take_sign_in_params(params) do
    params
    |> Map.take(["as", "state", "nonce", "redirect_to"])
    |> Map.reject(fn {_key, value} -> value in ["", nil] end)
  end

  # TODO: IDP REFACTOR
  # Remove this function once all accounts are migrated
  def fetch_token(sessions, account_id) do
    sessions
    |> Enum.find(fn {:browser, session_account_id, _encoded_fragment} ->
      session_account_id == account_id
    end)
    |> case do
      {_context_type, _account_id, encoded_fragment} -> {:ok, encoded_fragment}
      _ -> :error
    end
  end

  # TODO: IDP REFACTOR
  # Remove this function once all accounts are migrated
  def delete_account_session(conn, account_id) do
    sessions =
      Plug.Conn.get_session(conn, :sessions, [])
      |> Enum.reject(fn {:browser, session_account_id, _encoded_fragment} ->
        session_account_id == account_id
      end)

    Plug.Conn.put_session(conn, :sessions, sessions)
  end

  @doc """
  Takes sign in parameters returned by `take_sign_in_params/1` and
  returns the appropriate auth context type for them.
  """
  def fetch_auth_context_type!(%{"as" => "client"}), do: :client
  def fetch_auth_context_type!(_params), do: :browser

  def fetch_token_nonce!(%{"nonce" => nonce}), do: nonce
  def fetch_token_nonce!(_params), do: nil

  @doc """
  Persists the token in the session and redirects the user depending on the
  auth context type.

  The browser users are sent to authenticated home or a return path if it's stored in params.

  The account users are only expected to authenticate using client apps and are redirected
  to the deep link.
  """

  def signed_in(
        %Plug.Conn{} = conn,
        %Auth.Provider{} = provider,
        %Auth.Identity{} = identity,
        context,
        encoded_fragment,
        redirect_params
      ) do
    redirect_params = take_sign_in_params(redirect_params)
    conn = prepend_recent_account_ids(conn, provider.account_id)

    if is_nil(redirect_params["as"]) and identity.actor.type == :account_user do
      conn
      |> Phoenix.Controller.put_flash(
        :error,
        "You must have the admin role in Firezone to sign in to the admin portal."
      )
      |> Phoenix.Controller.redirect(to: ~p"/#{conn.path_params["account_id_or_slug"]}")
      |> Plug.Conn.halt()
    else
      conn
      |> put_account_session(context.type, provider.account_id, encoded_fragment)
      |> signed_in_redirect(identity, context, encoded_fragment, redirect_params)
    end
  end

  defp signed_in_redirect(conn, identity, %Auth.Context{type: :client}, encoded_fragment, %{
         "as" => "client",
         "nonce" => _nonce,
         "state" => state
       }) do
    Redirector.client_signed_in(
      conn,
      identity.actor.name,
      identity.provider_identifier,
      encoded_fragment,
      state
    )
  end

  defp signed_in_redirect(
         conn,
         _identity,
         %Auth.Context{type: :client},
         _encoded_fragment,
         _params
       ) do
    conn
    |> Phoenix.Controller.put_flash(
      :error,
      "You must have the admin role in Firezone to sign in to the admin portal."
    )
    |> Phoenix.Controller.redirect(to: ~p"/#{conn.path_params["account_id_or_slug"]}")
    |> Plug.Conn.halt()
  end

  defp signed_in_redirect(
         conn,
         _identity,
         %Auth.Context{type: :browser},
         _encoded_fragment,
         redirect_params
       ) do
    account = conn.assigns.account
    Redirector.portal_signed_in(conn, account, redirect_params)
  end

  @doc """
  This function renews the session ID to avoid fixation attacks
  and erases the session token from the sessions list.
  """

  # TODO: IDP REFACTOR
  # Can be removed once all accounts are migrated

  def renew_session(%Plug.Conn{} = conn) do
    preferred_locale = Plug.Conn.get_session(conn, :preferred_locale)
    account_id = if Map.get(conn.assigns, :account), do: conn.assigns.account.id

    sessions =
      Plug.Conn.get_session(conn, :sessions, [])
      |> Enum.reject(fn {_, session_account_id, _} ->
        session_account_id == account_id
      end)
      |> Enum.take(-1 * @remember_last_sessions)

    conn
    |> Plug.Conn.configure_session(renew: true)
    |> Plug.Conn.clear_session()
    |> Plug.Conn.put_session(:preferred_locale, preferred_locale)
    |> Plug.Conn.put_session(:sessions, sessions)
  end

  ###########################
  ## Controller Helpers
  ###########################

  def all_recent_account_ids(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@recent_accounts_cookie_name])

    if recent_account_ids = Map.get(conn.cookies, @recent_accounts_cookie_name) do
      {:ok, Plug.Crypto.non_executable_binary_to_term(recent_account_ids, [:safe]), conn}
    else
      {:ok, [], conn}
    end
  end

  defp prepend_recent_account_ids(conn, account_id) do
    update_recent_account_ids(conn, fn recent_account_ids ->
      [account_id] ++ recent_account_ids
    end)
  end

  def update_recent_account_ids(conn, callback) when is_function(callback, 1) do
    {:ok, recent_account_ids, conn} = all_recent_account_ids(conn)

    recent_account_ids =
      recent_account_ids
      |> callback.()
      |> Enum.take(@remember_last_account_ids)
      |> :erlang.term_to_binary()

    Plug.Conn.put_resp_cookie(
      conn,
      @recent_accounts_cookie_name,
      recent_account_ids,
      @recent_accounts_cookie_options
    )
  end

  def get_client_auth_data_from_cookie(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@client_auth_cookie_name])

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
  Attempts to execute a callback in the given constant time.

  If the time it takes to execute the callback is less than the timeout,
  the function will sleep for the remaining time. Otherwise, the function
  returns immediately.
  """
  def execute_with_constant_time(callback, constant_time) do
    start_time = System.monotonic_time(:millisecond)
    result = callback.()
    end_time = System.monotonic_time(:millisecond)

    elapsed_time = end_time - start_time
    remaining_time = max(0, constant_time - elapsed_time)

    if remaining_time > 0 do
      :timer.sleep(remaining_time)
    else
      log_constant_time_exceeded(constant_time, elapsed_time, remaining_time)
    end

    result
  end

  if Mix.env() in [:dev, :test] do
    def log_constant_time_exceeded(_constant_time, _elapsed_time, _remaining_time) do
      :ok
    end
  else
    def log_constant_time_exceeded(constant_time, elapsed_time, remaining_time) do
      Logger.error("Execution took longer than the given constant time",
        constant_time: constant_time,
        elapsed_time: elapsed_time,
        remaining_time: remaining_time
      )
    end
  end
end
