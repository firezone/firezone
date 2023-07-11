defmodule Web.AuthController do
  use Web, :controller
  alias Web.Auth
  alias Domain.Auth.Adapters.OpenIDConnect

  # This is the cookie which will be used to store the
  # state and code verifier for OpenID Connect IdP's
  @state_cookie_key_prefix "fz_auth_state_"
  @state_cookie_options [
    sign: true,
    max_age: 300,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  action_fallback Web.FallbackController

  @doc """
  This is a callback for the UserPass provider which checks login and password to authenticate the user.
  """
  def verify_credentials(conn, %{
        "account_id" => account_id,
        "provider_id" => provider_id,
        "userpass" => %{
          "provider_identifier" => provider_identifier,
          "secret" => secret
        }
      }) do
    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
         {:ok, subject} <-
           Domain.Auth.sign_in(
             provider,
             provider_identifier,
             secret,
             conn.assigns.user_agent,
             conn.remote_ip
           ) do
      redirect_to = get_session(conn, :user_return_to) || Auth.signed_in_path(subject)

      conn
      |> Web.Auth.renew_session()
      |> Web.Auth.put_subject_in_session(subject)
      |> redirect(to: redirect_to)
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:userpass_provider_identifier, String.slice(provider_identifier, 0, 160))
        |> put_flash(:error, "You can not use this method to sign in.")
        |> redirect(to: "/#{account_id}/sign_in")

      {:error, _reason} ->
        conn
        |> put_flash(:userpass_provider_identifier, String.slice(provider_identifier, 0, 160))
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: "/#{account_id}/sign_in")
    end
  end

  @doc """
  This is a callback for the Email provider which sends login link.
  """
  def request_magic_link(conn, %{
        "account_id" => account_id,
        "provider_id" => provider_id,
        "email" => %{
          "provider_identifier" => provider_identifier
        }
      }) do
    _ =
      with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
           {:ok, identity} <-
             Domain.Auth.fetch_identity_by_provider_and_identifier(provider, provider_identifier),
           {:ok, identity} <- Domain.Auth.Adapters.Email.request_sign_in_token(identity) do
        Web.Mailer.AuthEmail.sign_in_link_email(identity)
        |> Web.Mailer.deliver()
      end

    redirect(conn, to: "/#{account_id}/sign_in/providers/email/#{provider_id}")
  end

  @doc """
  This is a callback for the Email provider which handles both form submission and redirect login link
  to authenticate a user.
  """
  def verify_sign_in_token(conn, %{
        "account_id" => account_id,
        "provider_id" => provider_id,
        "identity_id" => identity_id,
        "secret" => secret
      }) do
    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
         {:ok, subject} <-
           Domain.Auth.sign_in(
             provider,
             identity_id,
             secret,
             conn.assigns.user_agent,
             conn.remote_ip
           ) do
      redirect_to = get_session(conn, :user_return_to) || Auth.signed_in_path(subject)

      conn
      |> Web.Auth.renew_session()
      |> Web.Auth.put_subject_in_session(subject)
      |> redirect(to: redirect_to)
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:error, "You can not use this method to sign in.")
        |> redirect(to: "/#{account_id}/sign_in")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "The sign in link is invalid or expired.")
        |> redirect(to: "/#{account_id}/sign_in")
    end
  end

  @doc """
  This controller redirects user to IdP for authentication while persisting
  verification state to prevent various attacks on OpenID Connect.
  """
  def redirect_to_idp(conn, %{"account_id" => account_id, "provider_id" => provider_id}) do
    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id) do
      redirect_url =
        url(~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/handle_callback")

      {:ok, authorization_url, {state, code_verifier}} =
        OpenIDConnect.authorization_uri(provider, redirect_url)

      key = state_cookie_key(provider.id)
      value = :erlang.term_to_binary({state, code_verifier})

      conn
      |> put_resp_cookie(key, value, @state_cookie_options)
      |> redirect(external: authorization_url)
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:error, "You can not use this method to sign in.")
        |> redirect(to: "/#{account_id}/sign_in")
    end
  end

  @doc """
  This controller handles IdP redirect back to the Firezone.
  """
  def handle_idp_callback(conn, %{
        "account_id" => account_id,
        "provider_id" => provider_id,
        "state" => state,
        "code" => code
      }) do
    key = state_cookie_key(provider_id)

    with {:ok, code_verifier} <- fetch_verified_state(conn, key, state),
         {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
         payload =
           {
             url(~p"/#{account_id}/sign_in/providers/#{provider_id}/handle_callback"),
             code_verifier,
             code
           },
         {:ok, subject} <-
           Domain.Auth.sign_in(
             provider,
             payload,
             conn.assigns.user_agent,
             conn.remote_ip
           ) do
      redirect_to = get_session(conn, :user_return_to) || Auth.signed_in_path(subject)

      conn
      |> delete_resp_cookie(key, @state_cookie_options)
      |> Web.Auth.renew_session()
      |> Web.Auth.put_subject_in_session(subject)
      |> redirect(to: redirect_to)
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:error, "You can not use this method to sign in.")
        |> redirect(to: "/#{account_id}/sign_in")

      {:error, :invalid_state} ->
        conn
        |> put_flash(:error, "Your session has expired, please try again.")
        |> redirect(to: "/#{account_id}/sign_in")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "You can not authenticate to this account.")
        |> redirect(to: "/#{account_id}/sign_in")
    end
  end

  defp fetch_verified_state(conn, key, state) do
    conn = fetch_cookies(conn, signed: [key])

    with {:ok, encoded_state} <- Map.fetch(conn.cookies, key),
         {persisted_state, persisted_verifier} <- :erlang.binary_to_term(encoded_state, [:safe]),
         :ok <- OpenIDConnect.ensure_states_equal(state, persisted_state) do
      {:ok, persisted_verifier}
    else
      _ -> {:error, :invalid_state}
    end
  end

  defp state_cookie_key(provider_id) do
    @state_cookie_key_prefix <> provider_id
  end

  def sign_out(conn, %{"account_id" => account_id}) do
    conn
    |> Auth.sign_out()
    |> redirect(to: ~p"/#{account_id}/sign_in")
  end
end
