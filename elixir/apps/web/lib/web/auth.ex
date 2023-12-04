defmodule Web.Auth do
  use Web, :verified_routes
  alias Domain.{Auth, Accounts}

  # This is the cookie which will store recent account ids
  # that the user has signed in to.
  @remember_me_cookie_name "fz_recent_account_ids"
  @remember_me_cookie_options [
    sign: true,
    max_age: 365 * 24 * 60 * 60,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]
  @remember_last_account_ids 5

  def signed_in_path(%Auth.Subject{actor: %{type: :account_admin_user}} = subject) do
    ~p"/#{subject.account}/sites"
  end

  def put_subject_in_session(conn, %Auth.Subject{} = subject) do
    {:ok, session_token} = Auth.create_session_token_from_subject(subject)

    session = {subject.account.id, DateTime.utc_now(), session_token}

    sessions =
      Plug.Conn.get_session(conn, :sessions, [])
      |> List.keystore(subject.account.id, 0, session)

    Plug.Conn.put_session(conn, :sessions, sessions)
  end

  @doc """
  Redirects the signed in user depending on the actor type.

  The account admin users are sent to authenticated home or a return path if it's stored in session.

  The account users are only expected to authenticate using client apps.
  If the platform is known, we direct them to the application through a deep link or an app link;
  if not, we guide them to the install instructions accompanied by an error message.
  """

  def signed_in_redirect(
        %Plug.Conn{path_params: %{"account_id_or_slug" => account_id_or_slug}} = conn,
        %Auth.Subject{account: %Accounts.Account{} = account},
        _client_platform,
        _client_csrf_token
      )
      when not is_nil(account_id_or_slug) and account_id_or_slug != account.id and
             account_id_or_slug != account.slug do
    conn
    |> Plug.Conn.delete_session(:user_return_to)
    |> Phoenix.Controller.redirect(to: ~p"/#{account_id_or_slug}")
  end

  def signed_in_redirect(
        conn,
        %Auth.Subject{} = subject,
        client_platform,
        client_csrf_token
      )
      when not is_nil(client_platform) and client_platform != "" do
    platform_redirects =
      Domain.Config.fetch_env!(:web, __MODULE__)
      |> Keyword.fetch!(:platform_redirects)
      |> Keyword.fetch!(:sign_in)

    if redirects = Map.get(platform_redirects, client_platform) do
      {:ok, client_token} = Auth.create_client_token_from_subject(subject)

      query =
        %{
          client_auth_token: client_token,
          client_csrf_token: client_csrf_token,
          actor_name: subject.actor.name,
          account_slug: subject.account.slug,
          account_name: subject.account.name,
          identity_provider_identifier: subject.identity.provider_identifier
        }
        |> Enum.reject(&is_nil(elem(&1, 1)))
        |> URI.encode_query()

      redirect_method = Keyword.fetch!(redirects, :method)
      redirect_dest = "#{Keyword.fetch!(redirects, :dest)}?#{query}"

      conn
      |> Plug.Conn.delete_session(:user_return_to)
      |> Phoenix.Controller.redirect([{redirect_method, redirect_dest}])
    else
      conn
      |> Phoenix.Controller.put_flash(
        :info,
        "Please use a client application to access Firezone."
      )
      |> Phoenix.Controller.redirect(to: ~p"/#{subject.account}")
    end
  end

  def signed_in_redirect(
        conn,
        %Auth.Subject{actor: %{type: :account_admin_user}} = subject,
        _client_platform,
        _client_csrf_token
      ) do
    redirect_to = Plug.Conn.get_session(conn, :user_return_to) || signed_in_path(subject)

    conn
    |> Web.Auth.put_subject_in_session(subject)
    |> Plug.Conn.delete_session(:user_return_to)
    |> Phoenix.Controller.redirect(to: redirect_to)
  end

  def signed_in_redirect(conn, %Auth.Subject{} = subject, _client_platform, _client_csrf_token) do
    conn
    |> Phoenix.Controller.put_flash(
      :info,
      "Please use a client application to access Firezone."
    )
    |> Phoenix.Controller.redirect(to: ~p"/#{subject.account}")
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See `renew_session/1`.
  """
  def sign_out(%Plug.Conn{} = conn, client_platform) do
    # TODO: deleted token from the database
    # _ = Auth.delete_subject_token(subject)

    if live_socket_id = Plug.Conn.get_session(conn, :live_socket_id) do
      conn.private.phoenix_endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    account_id_or_slug = Map.get(conn.assigns, :account) || conn.path_params["account_id_or_slug"]

    conn
    |> renew_session()
    |> sign_out_redirect(account_id_or_slug, client_platform)
  end

  defp sign_out_redirect(
         %{assigns: %{subject: %Auth.Subject{} = subject}} = conn,
         account_id_or_slug,
         client_platform
       ) do
    post_sign_out_url = post_sign_out_url(account_id_or_slug, client_platform)
    {:ok, _identity, redirect_url} = Auth.sign_out(subject.identity, post_sign_out_url)
    Phoenix.Controller.redirect(conn, external: redirect_url)
  end

  defp sign_out_redirect(conn, account_id_or_slug, client_platform) do
    Phoenix.Controller.redirect(conn,
      external: post_sign_out_url(account_id_or_slug, client_platform)
    )
  end

  defp post_sign_out_url(account_id_or_slug, client_platform) do
    platform_redirects =
      Domain.Config.fetch_env!(:web, __MODULE__)
      |> Keyword.fetch!(:platform_redirects)
      |> Keyword.fetch!(:sign_out)

    if redirects = Map.get(platform_redirects, client_platform) do
      redirect_method = Keyword.fetch!(redirects, :method)
      redirect_dest = Keyword.fetch!(redirects, :dest)

      cond do
        redirect_method == :external ->
          redirect_dest

        redirect_method == :to ->
          Web.Endpoint.url() <> redirect_dest
      end
    else
      url(~p"/#{account_id_or_slug}")
    end
  end

  @doc """
  This function renews the session ID to avoid fixation attacks and erases the session token from the sessions list.
  """
  def renew_session(%Plug.Conn{} = conn) do
    preferred_locale = Plug.Conn.get_session(conn, :preferred_locale)

    account_id = if Map.get(conn.assigns, :account), do: conn.assigns.account.id

    sessions =
      Plug.Conn.get_session(conn, :sessions, [])
      |> List.keydelete(account_id, 0)

    conn
    |> Plug.Conn.configure_session(renew: true)
    |> Plug.Conn.clear_session()
    |> Plug.Conn.put_session(:preferred_locale, preferred_locale)
    |> Plug.Conn.put_session(:sessions, sessions)
  end

  ###########################
  ## Controller Helpers
  ###########################

  def get_auth_context(%Plug.Conn{} = conn) do
    {location_region, location_city, {location_lat, location_lon}} =
      get_load_balancer_ip_location(conn)

    %Auth.Context{
      user_agent: Map.get(conn.assigns, :user_agent),
      remote_ip: conn.remote_ip,
      remote_ip_location_region: location_region,
      remote_ip_location_city: location_city,
      remote_ip_location_lat: location_lat,
      remote_ip_location_lon: location_lon
    }
  end

  def list_recent_account_ids(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@remember_me_cookie_name])

    if recent_account_ids = Map.get(conn.cookies, @remember_me_cookie_name) do
      {:ok, :erlang.binary_to_term(recent_account_ids, [:safe]), conn}
    else
      {:ok, [], conn}
    end
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
      @remember_me_cookie_name,
      recent_account_ids,
      @remember_me_cookie_options
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
    context = get_auth_context(conn)
    account_id = if Map.get(conn.assigns, :account), do: conn.assigns.account.id

    with sessions <- Plug.Conn.get_session(conn, :sessions, []),
         {_account_id, _logged_in_at, token} <-
           List.keyfind(sessions, account_id, 0),
         {:ok, subject} <- Auth.sign_in(token, context),
         true <- account_id == subject.account.id do
      conn
      |> Plug.Conn.put_session(:live_socket_id, "actors_sessions:#{subject.actor.id}")
      |> Plug.Conn.assign(:subject, subject)
    else
      _ ->
        conn
    end
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
    if conn.assigns[:subject] do
      client_platform =
        Plug.Conn.get_session(conn, :client_platform) || conn.query_params["client_platform"]

      client_csrf_token =
        Plug.Conn.get_session(conn, :client_csrf_token) || conn.query_params["client_csrf_token"]

      conn
      |> signed_in_redirect(conn.assigns[:subject], client_platform, client_csrf_token)
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.

  This plug will only work if there is an `account_id` in the path params.
  """
  def ensure_authenticated(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:subject] do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> Phoenix.Controller.redirect(to: ~p"/#{conn.path_params["account_id_or_slug"]}")
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
    Plug.Conn.put_session(conn, :user_return_to, Phoenix.Controller.current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

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
      Redirects to signed_in_path if there's a logged user.

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
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket.assigns[:subject]))}
    else
      {:cont, socket}
    end
  end

  defp mount_subject(socket, _params, session) do
    Phoenix.Component.assign_new(socket, :subject, fn ->
      user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
      real_ip = real_ip(socket)
      x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []

      {location_region, location_city, {location_lat, location_lon}} =
        get_load_balancer_ip_location(x_headers)

      context = %Auth.Context{
        user_agent: user_agent,
        remote_ip: real_ip,
        remote_ip_location_region: location_region,
        remote_ip_location_city: location_city,
        remote_ip_location_lat: location_lat,
        remote_ip_location_lon: location_lon
      }

      sessions = session["sessions"] || []
      account_id = if Map.get(socket.assigns, :account), do: socket.assigns.account.id

      with {_account_id, _logged_in_at, token} <- List.keyfind(sessions, account_id, 0),
           {:ok, subject} <- Auth.sign_in(token, context) do
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
