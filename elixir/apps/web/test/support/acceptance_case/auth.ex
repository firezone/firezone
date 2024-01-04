defmodule Web.AcceptanceCase.Auth do
  import ExUnit.Assertions

  def fetch_session_cookie(session) do
    options = Web.Session.options()

    key = Keyword.fetch!(options, :key)
    encryption_salt = Keyword.fetch!(options, :encryption_salt)
    signing_salt = Keyword.fetch!(options, :signing_salt)
    secret_key_base = Web.Endpoint.config(:secret_key_base)

    with {:ok, cookie} <- fetch_cookie(session, key),
         encryption_key = Plug.Crypto.KeyGenerator.generate(secret_key_base, encryption_salt, []),
         signing_key = Plug.Crypto.KeyGenerator.generate(secret_key_base, signing_salt, []),
         {:ok, decrypted} <-
           Plug.Crypto.MessageEncryptor.decrypt(
             cookie,
             encryption_key,
             signing_key
           ) do
      {:ok, Plug.Crypto.non_executable_binary_to_term(decrypted)}
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

  def authenticate(session, %Domain.Auth.Identity{} = identity) do
    user_agent = fetch_session_user_agent!(session)
    remote_ip = {127, 0, 0, 1}

    context = %Domain.Auth.Context{
      type: :browser,
      user_agent: user_agent,
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4501,
      remote_ip_location_lon: 30.5234,
      remote_ip: remote_ip
    }

    subject = Domain.Auth.build_subject(identity, nil, context)
    authenticate(session, subject)
  end

  def authenticate(session, %Domain.Auth.Subject{} = subject) do
    options = Web.Session.options()

    key = Keyword.fetch!(options, :key)
    encryption_salt = Keyword.fetch!(options, :encryption_salt)
    signing_salt = Keyword.fetch!(options, :signing_salt)
    secret_key_base = Web.Endpoint.config(:secret_key_base)

    with {:ok, token} <- Domain.Tokens.encode_fragment!(subject) do
      encryption_key = Plug.Crypto.KeyGenerator.generate(secret_key_base, encryption_salt, [])
      signing_key = Plug.Crypto.KeyGenerator.generate(secret_key_base, signing_salt, [])

      cookie =
        %{"sessions" => [{subject.account.id, DateTime.utc_now(), token}]}
        |> :erlang.term_to_binary()

      encrypted =
        Plug.Crypto.MessageEncryptor.encrypt(
          cookie,
          encryption_key,
          signing_key
        )

      Wallaby.Browser.set_cookie(session, key, encrypted)
    end
  end

  def assert_unauthenticated(session) do
    with {:ok, cookie} <- fetch_session_cookie(session) do
      case cookie["sessions"] do
        [{_, _, token} | _] ->
          user_agent = fetch_session_user_agent!(session)
          remote_ip = {127, 0, 0, 1}

          context = %Domain.Auth.Context{
            type: :browser,
            user_agent: user_agent,
            remote_ip: remote_ip
          }

          assert {:ok, subject} = Domain.Auth.authenticate(token, context)
          flunk("User is authenticated, identity: #{inspect(subject.identity)}")
          :ok

        [] ->
          session
      end
    else
      :error -> session
    end
  end

  def assert_authenticated(session, identity) do
    with {:ok, cookie} <- fetch_session_cookie(session),
         context = %Domain.Auth.Context{
           type: :browser,
           user_agent: fetch_session_user_agent!(session),
           remote_ip: {127, 0, 0, 1}
         },
         {_account_id, _logged_in_at, token} <-
           List.keyfind(cookie["sessions"], identity.account_id, 0),
         {:ok, subject} <- Domain.Auth.authenticate(token, context) do
      assert subject.identity.id == identity.id,
             "Expected #{inspect(identity)}, got #{inspect(subject.identity)}"

      session
    else
      :error -> flunk("No session cookie found")
      other -> flunk("User is not authenticated: #{inspect(other)}")
    end
  end

  defp fetch_session_user_agent!(session) do
    Enum.find_value(session.capabilities.chromeOptions.args, fn
      "--user-agent=" <> user_agent -> user_agent
      _ -> nil
    end)
  end
end
