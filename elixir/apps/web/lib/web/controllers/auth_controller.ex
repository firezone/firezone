defmodule Web.AuthController do
  use Web, :controller
  alias Web.Auth
  alias Domain.Auth.Adapters.OpenIDConnect

  # This is the cookie which will be used to store the
  # state during redirect to third-party website,
  # eg. state and code verifier for OpenID Connect IdP's
  @state_cookie_key_prefix "fz_auth_state_"
  @state_cookie_options [
    sign: true,
    # encrypt: true,
    max_age: 30 * 60,
    # If `same_site` is set to `Strict` then the cookie will not be sent on
    # IdP callback redirects, which will break the auth flow.
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  action_fallback Web.FallbackController

  @doc """
  This is a callback for the UserPass provider which checks login and password to authenticate the user.
  """
  def verify_credentials(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "provider_id" => provider_id,
          "userpass" => %{
            "provider_identifier" => provider_identifier,
            "secret" => secret
          }
        } = params
      ) do
    redirect_params = Web.Auth.take_sign_in_params(params)
    context_type = Web.Auth.fetch_auth_context_type!(redirect_params)
    context = Web.Auth.get_auth_context(conn, context_type)
    nonce = Web.Auth.fetch_token_nonce!(redirect_params)

    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
         {:ok, identity, encoded_fragment} <-
           Domain.Auth.sign_in(provider, provider_identifier, nonce, secret, context) do
      Web.Auth.signed_in(conn, provider, identity, context, encoded_fragment, redirect_params)
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:userpass_provider_identifier, String.slice(provider_identifier, 0, 160))
        |> put_flash(:error, "You may not use this method to sign in.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")

      {:error, _reason} ->
        conn
        |> put_flash(:userpass_provider_identifier, String.slice(provider_identifier, 0, 160))
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")
    end
  end

  @doc """
  This is a callback for the Email provider which sends login link.
  """
  def request_magic_link(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "provider_id" => provider_id,
          "email" => %{
            "provider_identifier" => provider_identifier
          }
        } = params
      ) do
    redirect_params = Web.Auth.take_sign_in_params(params)
    conn = maybe_send_magic_link_email(conn, provider_id, provider_identifier, redirect_params)
    redirect_params = Map.put(redirect_params, "provider_identifier", provider_identifier)

    conn
    |> maybe_put_resent_flash(params)
    |> redirect(
      to: ~p"/#{account_id_or_slug}/sign_in/providers/email/#{provider_id}?#{redirect_params}"
    )
  end

  defp maybe_send_magic_link_email(conn, provider_id, provider_identifier, redirect_params) do
    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
         {:ok, identity} <-
           Domain.Auth.fetch_active_identity_by_provider_and_identifier(
             provider,
             provider_identifier,
             preload: :account
           ),
         {:ok, identity} <- Domain.Auth.Adapters.Email.request_sign_in_token(identity) do
      # We split the secret into two components, the first 5 bytes is the code we send to the user
      # the rest is the secret we store in the cookie. This is to prevent authorization code injection
      # attacks where you can trick user into logging in into a attacker account.
      <<email_secret::binary-size(5), nonce::binary>> =
        identity.provider_virtual_state.sign_in_token

      {:ok, _} =
        Web.Mailer.AuthEmail.sign_in_link_email(
          identity,
          email_secret,
          conn.assigns.user_agent,
          conn.remote_ip,
          redirect_params
        )
        |> Web.Mailer.deliver()

      put_auth_state(conn, provider.id, {nonce, redirect_params})
    else
      _ -> conn
    end
  end

  defp maybe_put_resent_flash(conn, %{"resend" => "true"}),
    do: put_flash(conn, :info, "Email was resent.")

  defp maybe_put_resent_flash(conn, _params),
    do: conn

  @doc """
  This is a callback for the Email provider which handles both form submission and redirect login link
  to authenticate a user.
  """
  def verify_sign_in_token(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "provider_id" => provider_id,
          "identity_id" => identity_id,
          "secret" => email_secret
        } = params
      ) do
    with {:ok, {nonce, redirect_params}, conn} <- fetch_auth_state(conn, provider_id) do
      conn = delete_auth_state(conn, provider_id)
      secret = String.downcase(email_secret) <> nonce
      context_type = Web.Auth.fetch_auth_context_type!(redirect_params)
      context = Web.Auth.get_auth_context(conn, context_type)
      nonce = Web.Auth.fetch_token_nonce!(redirect_params)

      with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
           {:ok, identity, encoded_fragment} <-
             Domain.Auth.sign_in(provider, identity_id, nonce, secret, context) do
        Web.Auth.signed_in(conn, provider, identity, context, encoded_fragment, redirect_params)
      else
        {:error, :not_found} ->
          conn
          |> put_flash(:error, "You may not use this method to sign in.")
          |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")

        {:error, _reason} ->
          redirect_params = Map.put(redirect_params, "provider_identifier", identity_id)

          conn
          |> put_flash(:error, "The sign in token is invalid or expired.")
          |> redirect(
            to:
              ~p"/#{account_id_or_slug}/sign_in/providers/email/#{provider_id}?#{redirect_params}"
          )
      end
    else
      :error ->
        params = Web.Auth.take_sign_in_params(params)

        conn
        |> put_flash(:error, "The sign in token is expired.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{params}")
    end
  end

  @doc """
  This controller redirects user to IdP during sign in for authentication while persisting
  verification state to prevent various attacks on OpenID Connect.
  """
  def redirect_to_idp(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "provider_id" => provider_id
        } = params
      ) do
    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id) do
      redirect_url =
        url(~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/handle_callback")

      redirect_params = Web.Auth.take_sign_in_params(params)
      redirect_to_idp(conn, redirect_url, provider, %{}, redirect_params)
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:error, "You may not use this method to sign in.")
        |> redirect(to: ~p"/#{account_id_or_slug}")
    end
  end

  def redirect_to_idp(
        %Plug.Conn{} = conn,
        redirect_url,
        %Domain.Auth.Provider{} = provider,
        params \\ %{},
        redirect_params \\ %{}
      ) do
    {:ok, authorization_url, {state, code_verifier}} =
      OpenIDConnect.authorization_uri(provider, redirect_url, params)

    conn
    |> put_auth_state(provider.id, {redirect_params, state, code_verifier})
    |> redirect(external: authorization_url)
  end

  @doc """
  This controller handles IdP redirect back to the Firezone when user signs in.
  """
  def handle_idp_callback(conn, %{
        "account_id_or_slug" => account_id,
        "provider_id" => provider_id,
        "state" => state,
        "code" => code
      }) do
    with {:ok, redirect_params, code_verifier, conn} <-
           verify_idp_state_and_fetch_verifier(conn, provider_id, state) do
      payload = {
        url(~p"/#{account_id}/sign_in/providers/#{provider_id}/handle_callback"),
        code_verifier,
        code
      }

      context_type = Web.Auth.fetch_auth_context_type!(redirect_params)
      context = Web.Auth.get_auth_context(conn, context_type)
      nonce = Web.Auth.fetch_token_nonce!(redirect_params)

      with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
           {:ok, identity, encoded_fragment} <-
             Domain.Auth.sign_in(provider, nonce, payload, context) do
        Web.Auth.signed_in(conn, provider, identity, context, encoded_fragment, redirect_params)
      else
        {:error, :not_found} ->
          conn
          |> put_flash(:error, "You may not use this method to sign in.")
          |> redirect(to: ~p"/#{account_id}?#{redirect_params}")

        {:error, _reason} ->
          conn
          |> put_flash(:error, "You may not authenticate to this account.")
          |> redirect(to: ~p"/#{account_id}?#{redirect_params}")
      end
    else
      {:error, :invalid_state, conn} ->
        conn
        |> put_flash(:error, "Your session has expired, please try again.")
        |> redirect(to: ~p"/#{account_id}")
    end
  end

  def verify_idp_state_and_fetch_verifier(conn, provider_id, state) do
    with {:ok, {redirect_params, persisted_state, persisted_verifier}, conn} <-
           fetch_auth_state(conn, provider_id),
         :ok <- OpenIDConnect.ensure_states_equal(state, persisted_state) do
      {:ok, redirect_params, persisted_verifier, delete_auth_state(conn, provider_id)}
    else
      _ -> {:error, :invalid_state, delete_auth_state(conn, provider_id)}
    end
  end

  def sign_out(conn, params) do
    Auth.sign_out(conn, params)
  end

  @doc false
  def put_auth_state(conn, provider_id, state) do
    key = state_cookie_key(provider_id)
    value = :erlang.term_to_binary(state)
    put_resp_cookie(conn, key, value, @state_cookie_options)
  end

  defp fetch_auth_state(conn, provider_id) do
    key = state_cookie_key(provider_id)
    conn = fetch_cookies(conn, signed: [key])

    with {:ok, encoded_state} <- Map.fetch(conn.cookies, key) do
      {:ok, :erlang.binary_to_term(encoded_state, [:safe]), conn}
    end
  end

  defp delete_auth_state(conn, provider_id) do
    key = state_cookie_key(provider_id)
    delete_resp_cookie(conn, key, @state_cookie_options)
  end

  defp state_cookie_key(provider_id) do
    @state_cookie_key_prefix <> provider_id
  end
end
