defmodule Web.AuthController do
  use Web, :controller
  alias Web.Auth
  alias Domain.Auth.Adapters.OpenIDConnect
  require Logger

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

  @constant_execution_time Application.compile_env(:web, :constant_execution_time, 2000)

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
  def request_email_otp(
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

    with true <- String.contains?(provider_identifier, "@"),
         {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id) do
      conn = maybe_send_email_otp(conn, provider, provider_identifier, redirect_params)

      signed_provider_identifier =
        Plug.Crypto.sign(
          conn.secret_key_base,
          "signed_provider_identifier",
          provider_identifier
        )

      redirect_params =
        Map.put(
          redirect_params,
          "signed_provider_identifier",
          signed_provider_identifier
        )

      conn
      |> maybe_put_resent_flash(params)
      |> redirect(
        to: ~p"/#{account_id_or_slug}/sign_in/providers/email/#{provider.id}?#{redirect_params}"
      )
    else
      false ->
        conn
        |> put_flash(:error, "Invalid email address.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "You may not use this method to sign in.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")
    end
  end

  defp maybe_send_email_otp(conn, provider, provider_identifier, redirect_params) do
    context_type = Web.Auth.fetch_auth_context_type!(redirect_params)
    context = Web.Auth.get_auth_context(conn, context_type)

    fragment =
      Web.Auth.execute_with_constant_time(
        fn ->
          with {:ok, identity} <-
                 Domain.Auth.fetch_active_identity_by_provider_and_identifier(
                   provider,
                   provider_identifier,
                   preload: :account
                 ),
               {:ok, identity} <-
                 Domain.Auth.Adapters.Email.request_sign_in_token(identity, context),
               {:ok, fragment} <- send_email_otp(conn, identity, redirect_params) do
            fragment
          else
            _ ->
              # We generate a fake fragment to prevent information leakage,
              # otherwise you can tell if the email is registered or not
              # by looking at the cookies
              Domain.Tokens.encode_fragment!(%Domain.Tokens.Token{
                type: :email,
                secret_nonce: Domain.Crypto.random_token(5, encoder: :user_friendly),
                secret_fragment: Domain.Crypto.random_token(27, encoder: :hex32),
                account_id: Ecto.UUID.generate(),
                actor_id: Ecto.UUID.generate(),
                id: Ecto.UUID.generate(),
                expires_at: DateTime.utc_now(),
                created_by_user_agent: context.user_agent,
                created_by_remote_ip: context.remote_ip
              })
          end
        end,
        @constant_execution_time
      )

    put_auth_state(conn, provider.id, {fragment, provider_identifier, redirect_params})
  end

  defp send_email_otp(conn, identity, redirect_params) do
    # Nonce is the short part that is sent to the user in the email
    nonce = identity.provider_virtual_state.nonce

    # Fragment is stored in the browser to prevent authorization code injection
    # attacks where you can trick user into logging in into an attacker account.
    fragment = identity.provider_virtual_state.fragment

    Domain.Mailer.AuthEmail.sign_in_link_email(
      identity,
      nonce,
      conn.assigns.user_agent,
      conn.remote_ip,
      redirect_params
    )
    |> Domain.Mailer.deliver_with_rate_limit(
      rate_limit_key: {:sign_in_link, identity.id},
      rate_limit: 3,
      rate_limit_interval: :timer.minutes(5)
    )
    |> case do
      {:ok, _} -> {:ok, fragment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_resent_flash(%Plug.Conn{state: :unset} = conn, %{"resend" => "true"}),
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
          "secret" => nonce
        } = params
      ) do
    with {:ok, {fragment, provider_identifier, redirect_params}, conn} <-
           fetch_auth_state(conn, provider_id) do
      conn = delete_auth_state(conn, provider_id)
      secret = String.downcase(nonce) <> fragment
      context_type = Web.Auth.fetch_auth_context_type!(redirect_params)
      context = Web.Auth.get_auth_context(conn, context_type)
      nonce = Web.Auth.fetch_token_nonce!(redirect_params)

      with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
           {:ok, identity, encoded_fragment} <-
             Domain.Auth.sign_in(provider, identity_id, nonce, secret, context) do
        :ok = Domain.Mailer.RateLimiter.reset_rate_limit({:sign_in_link, identity.id})
        Web.Auth.signed_in(conn, provider, identity, context, encoded_fragment, redirect_params)
      else
        {:error, :not_found} ->
          conn
          |> put_flash(:error, "You may not use this method to sign in.")
          |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")

        {:error, _reason} ->
          signed_provider_identifier =
            Plug.Crypto.sign(
              conn.secret_key_base,
              "signed_provider_identifier",
              provider_identifier
            )

          redirect_params =
            Map.put(redirect_params, "signed_provider_identifier", signed_provider_identifier)

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
        %{"account_id_or_slug" => account_id_or_slug, "provider_id" => provider_id} = params
      ) do
    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
         redirect_params = Web.Auth.take_sign_in_params(params),
         redirect_url =
           url(~p"/#{provider.account_id}/sign_in/providers/#{provider}/handle_callback"),
         {:ok, conn} <- redirect_to_idp(conn, redirect_url, provider, %{}, redirect_params) do
      conn
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:error, "You may not use this method to sign in.")
        |> redirect(to: ~p"/#{account_id_or_slug}")

      {:error, {status, body}} ->
        Logger.warning("Failed to redirect to IdP", status: status, body: inspect(body))

        conn
        |> put_flash(:error, "Your identity provider returned #{status} HTTP code.")
        |> redirect(to: ~p"/#{account_id_or_slug}")

      {:error, %{reason: :timeout}} ->
        Logger.warning("Failed to redirect to IdP", reason: :timeout)

        conn
        |> put_flash(:error, "Your identity provider took too long to respond.")
        |> redirect(to: ~p"/#{account_id_or_slug}")

      {:error, reason} ->
        Logger.warning("Failed to redirect to IdP", reason: inspect(reason))

        conn
        |> put_flash(:error, "Your identity provider is not available right now.")
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
    with {:ok, authorization_url, {state, code_verifier}} <-
           OpenIDConnect.authorization_uri(provider, redirect_url, params) do
      conn =
        conn
        |> put_auth_state(provider.id, {redirect_params, state, code_verifier})
        |> redirect(external: authorization_url)

      {:ok, conn}
    end
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

  def handle_idp_callback(conn, %{
        "account_id_or_slug" => account_id
      }) do
    conn
    |> put_flash(:error, "Invalid request.")
    |> redirect(to: ~p"/#{account_id}")
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
      {:ok, Plug.Crypto.non_executable_binary_to_term(encoded_state, [:safe]), conn}
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
