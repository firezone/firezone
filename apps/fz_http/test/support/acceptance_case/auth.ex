defmodule FzHttpWeb.AcceptanceCase.Auth do
  import ExUnit.Assertions

  def fetch_session_cookie(session) do
    options = FzHttpWeb.Session.options()

    key = Keyword.fetch!(options, :key)
    encryption_salt = Keyword.fetch!(options, :encryption_salt)
    signing_salt = Keyword.fetch!(options, :signing_salt)
    secret_key_base = FzHttpWeb.Endpoint.config(:secret_key_base)

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

  def authenticate(session, %FzHttp.Users.User{} = user) do
    options = FzHttpWeb.Session.options()

    key = Keyword.fetch!(options, :key)
    encryption_salt = Keyword.fetch!(options, :encryption_salt)
    signing_salt = Keyword.fetch!(options, :signing_salt)
    secret_key_base = FzHttpWeb.Endpoint.config(:secret_key_base)

    with {:ok, token, _claims} <- FzHttpWeb.Auth.HTML.Authentication.encode_and_sign(user) do
      encryption_key = Plug.Crypto.KeyGenerator.generate(secret_key_base, encryption_salt, [])
      signing_key = Plug.Crypto.KeyGenerator.generate(secret_key_base, signing_salt, [])

      cookie =
        %{
          "guardian_default_token" => token,
          "login_method" => "identity",
          "logged_in_at" => DateTime.utc_now()
        }
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
      if token = cookie["guardian_default_token"] do
        {:ok, claims} = FzHttpWeb.Auth.HTML.Authentication.decode_and_verify(token)
        flunk("User is authenticated, claims: #{inspect(claims)}")
      else
        session
      end
    else
      :error -> session
    end
  end

  def assert_authenticated(session, user) do
    with {:ok, cookie} <- fetch_session_cookie(session),
         {:ok, claims} <-
           FzHttpWeb.Auth.HTML.Authentication.decode_and_verify(cookie["guardian_default_token"]),
         {:ok, authenticated_user} <-
           FzHttpWeb.Auth.HTML.Authentication.resource_from_claims(claims) do
      assert authenticated_user.id == user.id
      session
    else
      :error -> flunk("No session cookie found")
      other -> flunk("User is not authenticated: #{inspect(other)}")
    end
  end
end
