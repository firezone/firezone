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

  # def authenticate(session, %Domain.Users.User{} = user) do
  #   subject = Domain.Auth.fetch_subject!(user, "127.0.0.1", "AcceptanceCase")
  #   authenticate(session, subject)
  # end

  # def authenticate(session, %Domain.Auth.Subject{} = subject) do
  #   options = Web.Session.options()

  #   key = Keyword.fetch!(options, :key)
  #   encryption_salt = Keyword.fetch!(options, :encryption_salt)
  #   signing_salt = Keyword.fetch!(options, :signing_salt)
  #   secret_key_base = Web.Endpoint.config(:secret_key_base)

  #   with {:ok, token, _claims} <- Web.Auth.HTML.Authentication.encode_and_sign(subject) do
  #     encryption_key = Plug.Crypto.KeyGenerator.generate(secret_key_base, encryption_salt, [])
  #     signing_key = Plug.Crypto.KeyGenerator.generate(secret_key_base, signing_salt, [])

  #     cookie =
  #       %{
  #         "guardian_default_token" => token,
  #         "login_method" => "identity",
  #         "logged_in_at" => DateTime.utc_now()
  #       }
  #       |> :erlang.term_to_binary()

  #     encrypted =
  #       Plug.Crypto.MessageEncryptor.encrypt(
  #         cookie,
  #         encryption_key,
  #         signing_key
  #       )

  #     Wallaby.Browser.set_cookie(session, key, encrypted)
  #   end
  # end

  # TODO
  # def assert_unauthenticated(session) do
  #   with {:ok, cookie} <- fetch_session_cookie(session) do
  #     if token = cookie["guardian_default_token"] do
  #       # TODO
  #       # {:ok, claims} = Web.Auth.HTML.Authentication.decode_and_verify(token)
  #       # flunk("User is authenticated, claims: #{inspect(claims)}")
  #       :ok
  #     else
  #       session
  #     end
  #   else
  #     :error -> session
  #   end
  # end

  # def assert_authenticated(session, user) do
  #   with {:ok, cookie} <- fetch_session_cookie(session) do
  #     # TODO
  #     #  {:ok, claims} <-
  #     #    Web.Auth.HTML.Authentication.decode_and_verify(cookie["guardian_default_token"]),
  #     #  {:ok, subject} <-
  #     #    Web.Auth.HTML.Authentication.resource_from_claims(claims) do
  #     # assert elem(subject.actor, 1).id == user.id
  #     session
  #   else
  #     :error -> flunk("No session cookie found")
  #     other -> flunk("User is not authenticated: #{inspect(other)}")
  #   end
  # end
end
