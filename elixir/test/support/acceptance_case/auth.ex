defmodule PortalWeb.AcceptanceCase.Auth do
  @moduledoc """
  Helper module for authentication in acceptance (browser) tests.

  Uses the per-account session cookie system for portal authentication.
  """
  import ExUnit.Assertions

  @doc """
  Fetches the session cookie for a given account from the browser session.

  Returns the session ID if found and valid.
  """
  def fetch_session_cookie(session, account_id) do
    cookie_name = "sess_#{account_id}"
    signing_salt = Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
    secret_key_base = PortalWeb.Endpoint.config(:secret_key_base)

    with {:ok, cookie_value} <- fetch_cookie(session, cookie_name) do
      # The cookie is signed, not encrypted
      case Plug.Crypto.verify(secret_key_base, signing_salt, cookie_value) do
        {:ok, <<_::128>> = session_id_binary} ->
          {:ok, Ecto.UUID.load!(session_id_binary)}

        {:error, _reason} ->
          :error
      end
    end
  end

  defp fetch_cookie(session, key) do
    cookies = Wallaby.Browser.cookies(session)

    if cookie = Enum.find(cookies, fn cookie -> Map.get(cookie, "name") == key end) do
      Map.fetch(cookie, "value")
    else
      :error
    end
  end

  @doc """
  Creates a portal session for the given actor and sets the session cookie in the browser.

  This allows acceptance tests to authenticate a user without going through the full
  sign-in flow.
  """
  def authenticate(session, %Portal.Actor{} = actor, %Portal.AuthProvider{} = provider) do
    user_agent = fetch_session_user_agent!(session)
    remote_ip = {127, 0, 0, 1}

    context = %Portal.Auth.Context{
      type: :portal,
      user_agent: user_agent,
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4501,
      remote_ip_location_lon: 30.5234,
      remote_ip: remote_ip
    }

    expires_at = DateTime.add(DateTime.utc_now(), 8 * 60 * 60, :second)

    {:ok, portal_session} =
      Portal.Auth.create_portal_session(actor, provider.id, context, expires_at)

    # Create signed cookie value
    signing_salt = Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
    secret_key_base = PortalWeb.Endpoint.config(:secret_key_base)

    cookie_value =
      portal_session.id
      |> Ecto.UUID.dump!()
      |> then(&Plug.Crypto.sign(secret_key_base, signing_salt, &1))

    cookie_name = "sess_#{actor.account_id}"
    Wallaby.Browser.set_cookie(session, cookie_name, cookie_value)
  end

  @doc """
  Asserts that the browser session is not authenticated for the given account.
  """
  def assert_unauthenticated(session, account_id) do
    case fetch_session_cookie(session, account_id) do
      {:ok, session_id} ->
        case Portal.Auth.fetch_portal_session(account_id, session_id) do
          {:ok, _portal_session} ->
            flunk("User is authenticated but should not be")

          {:error, :not_found} ->
            session
        end

      :error ->
        session
    end
  end

  @doc """
  Sets up a Bypass server to mock the client sign-in callback endpoint.
  """
  def mock_client_sign_in_callback do
    test_pid = self()
    bypass = Bypass.open()
    Portal.Config.put_env_override(:portal, :client_handler, "http://localhost:#{bypass.port}/")

    Bypass.expect_once(bypass, "GET", "/handle_client_sign_in_callback", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:handle_client_sign_in_callback, conn.query_params})
      Plug.Conn.send_resp(conn, 200, "Client redirected")
    end)

    Bypass.stub(bypass, "GET", "/favicon.ico", fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    bypass
  end

  @doc """
  Asserts that the browser session is authenticated with a session for the given actor.
  """
  def assert_authenticated(session, %Portal.Actor{} = actor) do
    case fetch_session_cookie(session, actor.account_id) do
      {:ok, session_id} ->
        case Portal.Auth.fetch_portal_session(actor.account_id, session_id) do
          {:ok, portal_session} ->
            assert portal_session.actor_id == actor.id,
                   "Expected actor #{actor.id}, got #{portal_session.actor_id}"

            session

          {:error, :not_found} ->
            flunk("Session cookie exists but session not found in database")
        end

      :error ->
        flunk("No session cookie found for account #{actor.account_id}")
    end
  end

  defp fetch_session_user_agent!(session) do
    Enum.find_value(session.capabilities.chromeOptions.args, fn
      "--user-agent=" <> user_agent -> user_agent
      _ -> nil
    end)
  end
end
