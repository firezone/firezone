defmodule Web.Auth do
  use Web, :verified_routes
  alias Domain.{Auth, Accounts, Tokens}

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

    Plug.Conn.put_session(conn, :sessions, sessions)
  end

  defp delete_account_session(conn, context_type, account_id) do
    sessions =
      Plug.Conn.get_session(conn, :sessions, [])
      |> Enum.reject(fn {session_context_type, session_account_id, _encoded_fragment} ->
        session_context_type == context_type and session_account_id == account_id
      end)

    Plug.Conn.put_session(conn, :sessions, sessions)
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
        "Please use a client application to access Firezone."
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
    query =
      %{
        fragment: encoded_fragment,
        state: state,
        actor_name: identity.actor.name,
        account_slug: conn.assigns.account.slug,
        account_name: conn.assigns.account.name,
        identity_provider_identifier: identity.provider_identifier
      }
      |> Enum.reject(&is_nil(elem(&1, 1)))
      |> URI.encode_query()

    client_handler =
      Domain.Config.fetch_env!(:web, :client_handler)

    Phoenix.Controller.redirect(conn,
      external: "#{client_handler}handle_client_sign_in_callback?#{query}"
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
    |> Phoenix.Controller.put_flash(:error, "Please use a client application to access Firezone.")
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
    redirect_to = signed_in_path(account, redirect_params)
    Phoenix.Controller.redirect(conn, to: redirect_to)
  end

  defp signed_in_path(%Accounts.Account{} = account, %{"redirect_to" => redirect_to})
       when is_binary(redirect_to) do
    if String.starts_with?(redirect_to, "/#{account.id}") or
         String.starts_with?(redirect_to, "/#{account.slug}") do
      redirect_to
    else
      signed_in_path(account)
    end
  end

  defp signed_in_path(%Accounts.Account{} = account, _redirect_params) do
    signed_in_path(account)
  end

  defp signed_in_path(%Accounts.Account{} = account) do
    ~p"/#{account}/sites"
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See `renew_session/1`.
  """
  def sign_out(%Plug.Conn{} = conn, params) do
    account_or_slug = Map.get(conn.assigns, :account) || params["account_id_or_slug"]

    conn
    |> renew_session()
    |> sign_out_redirect(account_or_slug, params)
  end

  defp sign_out_redirect(
         %{assigns: %{subject: %Auth.Subject{} = subject}} = conn,
         account_or_slug,
         params
       ) do
    post_sign_out_url = post_sign_out_url(account_or_slug, params)
    {:ok, _identity, redirect_url} = Auth.sign_out(subject, post_sign_out_url)
    Phoenix.Controller.redirect(conn, external: redirect_url)
  end

  defp sign_out_redirect(conn, account_or_slug, params) do
    post_sign_out_url = post_sign_out_url(account_or_slug, params)
    Phoenix.Controller.redirect(conn, external: post_sign_out_url)
  end

  defp post_sign_out_url(_account_or_slug, %{"as" => "client", "state" => state}) do
    "firezone://handle_client_sign_out_callback?state=#{state}"
  end

  defp post_sign_out_url(account_or_slug, _params) do
    url(~p"/#{account_or_slug}")
  end

  @doc """
  This function renews the session ID to avoid fixation attacks
  and erases the session token from the sessions list.
  """
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

  def list_recent_account_ids(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@recent_accounts_cookie_name])

    if recent_account_ids = Map.get(conn.cookies, @recent_accounts_cookie_name) do
      {:ok, :erlang.binary_to_term(recent_account_ids, [:safe]), conn}
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
    {:ok, recent_account_ids, conn} = list_recent_account_ids(conn)

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

  ###########################
  ## Plugs
  ###########################

  @doc """
  Fetches the user agent value from headers and assigns it the connection.
  """
  def fetch_user_agent(%Plug.Conn{} = conn, _opts) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [user_agent | _] -> Plug.Conn.assign(conn, :user_agent, user_agent)
      _ -> conn
    end
  end

  def fetch_account(%Plug.Conn{path_info: [account_id_or_slug | _]} = conn, _opts) do
    case Accounts.fetch_account_by_id_or_slug(account_id_or_slug) do
      {:ok, account} -> Plug.Conn.assign(conn, :account, account)
      _ -> conn
    end
  end

  def fetch_account(%Plug.Conn{} = conn, _opts) do
    conn
  end

  @doc """
  Fetches the session token from the session and assigns the subject to the connection.
  """
  def fetch_subject(%Plug.Conn{} = conn, _opts) do
    params = take_sign_in_params(conn.params)
    context_type = fetch_auth_context_type!(params)
    context = get_auth_context(conn, context_type)

    if account = Map.get(conn.assigns, :account) do
      sessions = Plug.Conn.get_session(conn, :sessions, [])

      with {:ok, encoded_fragment} <- fetch_token(sessions, account.id, context.type),
           {:ok, subject} <- Auth.authenticate(encoded_fragment, context),
           true <- subject.account.id == account.id do
        conn
        |> Plug.Conn.put_session(:live_socket_id, Tokens.socket_id(subject.token_id))
        |> Plug.Conn.assign(:subject, subject)
      else
        {:error, :unauthorized} ->
          delete_account_session(conn, context.type, account.id)

        _ ->
          conn
      end
    else
      conn
    end
  end

  defp fetch_token(sessions, account_id, context_type) do
    sessions
    |> Enum.find(fn {session_context_type, session_account_id, _encoded_fragment} ->
      session_context_type == context_type and session_account_id == account_id
    end)
    |> case do
      {_context_type, _account_id, encoded_fragment} -> {:ok, encoded_fragment}
      _ -> :error
    end
  end

  def get_auth_context(%Plug.Conn{} = conn, type) do
    {location_region, location_city, {location_lat, location_lon}} =
      get_load_balancer_ip_location(conn)

    %Auth.Context{
      type: type,
      user_agent: Map.get(conn.assigns, :user_agent),
      remote_ip: conn.remote_ip,
      remote_ip_location_region: location_region,
      remote_ip_location_city: location_city,
      remote_ip_location_lat: location_lat,
      remote_ip_location_lon: location_lon
    }
  end

  defp get_load_balancer_ip_location(%Plug.Conn{} = conn) do
    location_region =
      case Plug.Conn.get_req_header(conn, "x-geo-location-region") do
        ["" | _] -> nil
        [location_region | _] -> location_region
        [] -> nil
      end

    location_city =
      case Plug.Conn.get_req_header(conn, "x-geo-location-city") do
        ["" | _] -> nil
        [location_city | _] -> location_city
        [] -> nil
      end

    {location_lat, location_lon} =
      case Plug.Conn.get_req_header(conn, "x-geo-location-coordinates") do
        ["" | _] ->
          {nil, nil}

        ["," | _] ->
          {nil, nil}

        [coordinates | _] ->
          [lat, lon] = String.split(coordinates, ",", parts: 2)
          lat = String.to_float(lat)
          lon = String.to_float(lon)
          {lat, lon}

        [] ->
          {nil, nil}
      end

    {location_lat, location_lon} =
      Domain.Geo.maybe_put_default_coordinates(location_region, {location_lat, location_lon})

    {location_region, location_city, {location_lat, location_lon}}
  end

  defp get_load_balancer_ip_location(x_headers) do
    location_region =
      case get_socket_header(x_headers, "x-geo-location-region") do
        {"x-geo-location-region", ""} -> nil
        {"x-geo-location-region", location_region} -> location_region
        _other -> nil
      end

    location_city =
      case get_socket_header(x_headers, "x-geo-location-city") do
        {"x-geo-location-city", ""} -> nil
        {"x-geo-location-city", location_city} -> location_city
        _other -> nil
      end

    {location_lat, location_lon} =
      case get_socket_header(x_headers, "x-geo-location-coordinates") do
        {"x-geo-location-coordinates", ""} ->
          {nil, nil}

        {"x-geo-location-coordinates", coordinates} ->
          [lat, lon] = String.split(coordinates, ",", parts: 2)
          lat = String.to_float(lat)
          lon = String.to_float(lon)
          {lat, lon}

        _other ->
          {nil, nil}
      end

    {location_lat, location_lon} =
      Domain.Geo.maybe_put_default_coordinates(location_region, {location_lat, location_lon})

    {location_region, location_city, {location_lat, location_lon}}
  end

  defp get_socket_header(x_headers, key) do
    List.keyfind(x_headers, key, 0)
  end

  @doc """
  Used for routes that require the user to not be authenticated.
  """
  def redirect_if_user_is_authenticated(%Plug.Conn{} = conn, _opts) do
    if subject = conn.assigns[:subject] do
      redirect_params = take_sign_in_params(conn.params)
      encoded_fragment = fetch_subject_token!(conn, subject)
      identity = %{subject.identity | actor: subject.actor}

      conn
      |> signed_in_redirect(identity, subject.context, encoded_fragment, redirect_params)
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  defp fetch_subject_token!(conn, %Auth.Subject{} = subject) do
    sessions = Plug.Conn.get_session(conn, :sessions, [])
    {:ok, encoded_fragment} = fetch_token(sessions, subject.account.id, subject.context.type)
    encoded_fragment
  end

  @doc """
  Used for routes that require the user to be authenticated.

  This plug will only work if there is an `account_id` in the path params.
  """
  def ensure_authenticated(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:subject] do
      conn
    else
      redirect_params = maybe_store_return_to(conn)

      conn
      |> Phoenix.Controller.put_flash(:error, "You must log in to access this page.")
      |> Phoenix.Controller.redirect(
        to: ~p"/#{conn.path_params["account_id_or_slug"]}?#{redirect_params}"
      )
      |> Plug.Conn.halt()
    end
  end

  @doc """
  Used for routes that require the user to be authenticated as a specific kind of actor.

  This plug will only work if there is an `account_id` in the path params.
  """
  def ensure_authenticated_actor_type(%Plug.Conn{} = conn, type) do
    if not is_nil(conn.assigns[:subject]) and conn.assigns[:subject].actor.type == type do
      conn
    else
      conn
      |> Web.FallbackController.call({:error, :not_found})
      |> Plug.Conn.halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    %{"redirect_to" => Phoenix.Controller.current_path(conn)}
  end

  defp maybe_store_return_to(_conn) do
    %{}
  end

  ###########################
  ## LiveView
  ###########################

  @doc """
  Handles mounting and authenticating the actor in LiveViews.

  Notice: every protected route should have `account_id` in the path params.

  ## `on_mount` arguments

    * `:mount_subject` - assigns user_agent and subject to the socket assigns based on
      session_token, or nil if there's no session_token or no matching user.

    * `:ensure_authenticated` - authenticates the user from the session,
      and assigns the subject to socket assigns based on session_token.
      Redirects to login page if there's no logged user.

    * `:redirect_if_user_is_authenticated` - authenticates the user from the session.
      Redirects to signed in path if there's a logged user.

    * `:mount_account` - takes `account_id` from path params and loads the given account
      into the socket assigns using the `subject` mounted via `:mount_subject`. This is useful
      because some actions can be performed by superadmin users on behalf of other accounts
      so we can't really rely on `subject.account` in a lot of places.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the subject:

      defmodule Web.Page do
        use Web, :live_view

        on_mount {Web.UserAuth, :mount_subject}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{Web.UserAuth, :ensure_authenticated}] do
        live "/:account_id/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_subject, params, session, socket) do
    socket = mount_account(socket, params, session)
    {:cont, mount_subject(socket, params, session)}
  end

  def on_mount(:mount_account, params, session, socket) do
    {:cont, mount_account(socket, params, session)}
  end

  def on_mount(:ensure_authenticated, params, session, socket) do
    socket = mount_account(socket, params, session)
    socket = mount_subject(socket, params, session)

    if socket.assigns[:subject] do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/#{params["account_id_or_slug"]}")

      {:halt, socket}
    end
  end

  def on_mount(:ensure_account_admin_user_actor, params, session, socket) do
    socket = mount_account(socket, params, session)
    socket = mount_subject(socket, params, session)

    if socket.assigns[:subject].actor.type == :account_admin_user do
      {:cont, socket}
    else
      raise Web.LiveErrors.NotFoundError
    end
  end

  def on_mount(:redirect_if_user_is_authenticated, params, session, socket) do
    socket = mount_account(socket, params, session)
    socket = mount_subject(socket, params, session)

    if socket.assigns[:subject] do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket.assigns.account))}
    else
      {:cont, socket}
    end
  end

  # TODO: we need to schedule socket expiration for this subject, so that when it expires
  # LiveView socket will be disconnected. Otherwise, you can keep using the system as long as
  # socket is active extending the session.
  defp mount_subject(socket, params, session) do
    Phoenix.Component.assign_new(socket, :subject, fn ->
      params = take_sign_in_params(params)
      context_type = fetch_auth_context_type!(params)
      user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
      real_ip = real_ip(socket)
      x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []

      {location_region, location_city, {location_lat, location_lon}} =
        get_load_balancer_ip_location(x_headers)

      context = %Auth.Context{
        type: context_type,
        user_agent: user_agent,
        remote_ip: real_ip,
        remote_ip_location_region: location_region,
        remote_ip_location_city: location_city,
        remote_ip_location_lat: location_lat,
        remote_ip_location_lon: location_lon
      }

      sessions = session["sessions"] || []

      with account when not is_nil(account) <- Map.get(socket.assigns, :account),
           {:ok, encoded_fragment} <- fetch_token(sessions, account.id, context.type),
           {:ok, subject} <- Auth.authenticate(encoded_fragment, context),
           true <- subject.account.id == account.id do
        subject
      else
        _ -> nil
      end
    end)
  end

  defp mount_account(socket, %{"account_id_or_slug" => account_id_or_slug}, _session) do
    Phoenix.Component.assign_new(socket, :account, fn ->
      with {:ok, account} <-
             Accounts.fetch_account_by_id_or_slug(account_id_or_slug) do
        account
      else
        _ -> nil
      end
    end)
  end

  def real_ip(socket) do
    peer_data = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers)

    real_ip =
      if is_list(x_headers) and length(x_headers) > 0 do
        RemoteIp.from(x_headers, Web.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
  end
end
