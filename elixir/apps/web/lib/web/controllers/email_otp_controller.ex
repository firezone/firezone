defmodule Web.EmailOTPController do
  @moduledoc """
  Controller for handling email OTP authentication for migrated accounts.
  """
  use Web, :controller

  alias Domain.{
    Accounts,
    Auth,
    EmailOTP,
    Repo,
    Tokens
  }

  alias Web.Session.Redirector

  require Logger

  # Session length - matches session cookie max age
  @session_token_hours 8

  # For persisting state across the email OTP flow
  @cookie_key "email_otp"
  @cookie_options [
    sign: true,
    max_age: 30 * 60,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  @constant_execution_time Application.compile_env(:web, :constant_execution_time, 2000)

  action_fallback Web.FallbackController

  def sign_in(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "auth_provider_id" => auth_provider_id,
          "email" => email_params
        } = params
      ) do
    idp_id = email_params["idp_id"]

    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
         %EmailOTP.AuthProvider{} <- fetch_provider(account, auth_provider_id) do
      conn = maybe_send_email_otp(conn, account, idp_id, params, auth_provider_id)

      signed_idp_id =
        Plug.Crypto.sign(conn.secret_key_base, "signed_idp_id", idp_id)

      redirect_params =
        params
        |> sanitize()
        |> Map.put("signed_idp_id", signed_idp_id)

      conn
      |> maybe_put_resent_flash(params)
      |> redirect(
        to: ~p"/#{account_id_or_slug}/sign_in/email_otp/#{auth_provider_id}?#{redirect_params}"
      )
    else
      error ->
        handle_error(conn, error, params)
    end
  end

  def sign_in(conn, params) do
    Logger.warning("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  def verify(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "auth_provider_id" => auth_provider_id,
          "secret" => nonce
        } = params
      ) do
    cookie_key = state_cookie_key(auth_provider_id)
    conn = fetch_cookies(conn, signed: [cookie_key])
    context_type = context_type(params)
    issuer = "firezone"

    with {:ok, cookie_binary} <- Map.fetch(conn.cookies, cookie_key),
         {fragment, idp_id, _stored_params} <- :erlang.binary_to_term(cookie_binary),
         conn = delete_resp_cookie(conn, cookie_key),
         {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
         %EmailOTP.AuthProvider{} <- fetch_provider(account, auth_provider_id),
         %Auth.Identity{} = identity <- fetch_identity(account, issuer, idp_id),
         :ok <- check_admin(identity, context_type),
         secret = String.downcase(nonce) <> fragment,
         {:ok, identity, _expires_at} <- verify_secret(identity, secret, conn),
         {:ok, token} <- create_token(conn, identity, params) do
      :ok = Domain.Mailer.RateLimiter.reset_rate_limit({:sign_in_link, identity.id})
      signed_in(conn, context_type, account, identity, token, params)
    else
      error ->
        handle_error(conn, error, params)
    end
  end

  def verify(conn, params) do
    Logger.warning("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  defp maybe_send_email_otp(conn, account, idp_id, params, auth_provider_id) do
    context_type = context_type(params)
    context = auth_context(conn, context_type)
    issuer = "firezone"

    {fragment, error} =
      Web.Auth.execute_with_constant_time(
        fn ->
          with %Auth.Identity{} = identity <- fetch_identity(account, issuer, idp_id),
               {:ok, identity} <-
                 Domain.Auth.Adapters.Email.request_sign_in_token(identity, context),
               {:ok, fragment} <- send_email_otp(conn, identity, params) do
            {fragment, nil}
          else
            {:error, :rate_limited} ->
              # Generate fake fragment but track the error
              fake_fragment =
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

              {fake_fragment, :rate_limited}

            _ ->
              # We generate a fake fragment to prevent information leakage
              fake_fragment =
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

              {fake_fragment, nil}
          end
        end,
        @constant_execution_time
      )

    conn = put_auth_state(conn, auth_provider_id, {fragment, idp_id, sanitize(params)})

    case error do
      :rate_limited ->
        put_flash(
          conn,
          :error,
          "Too many sign-in attempts. Please wait a few minutes and try again."
        )

      _ ->
        conn
    end
  end

  defp fetch_provider(account, id) do
    import Ecto.Query

    # Fetch the email OTP auth provider by account and id, ensuring it is not disabled
    from(p in EmailOTP.AuthProvider,
      where: p.account_id == ^account.id and p.id == ^id and not p.is_disabled
    )
    |> Repo.one()
  end

  defp fetch_identity(account, issuer, idp_id) do
    import Ecto.Query

    account_id = account.id

    # Fetch identity by idp_id, issuer, and account_id, ensuring the associated actor is not disabled
    from(i in Auth.Identity,
      where: i.idp_id == ^idp_id and i.issuer == ^issuer and i.account_id == ^account_id
    )
    |> join(:inner, [i], a in assoc(i, :actor))
    |> where([_i, a], is_nil(a.disabled_at))
    |> Repo.one()
  end

  defp send_email_otp(conn, identity, params) do
    nonce = identity.provider_virtual_state.nonce
    fragment = identity.provider_virtual_state.fragment

    Domain.Mailer.AuthEmail.sign_in_link_email(
      identity,
      nonce,
      conn.assigns.user_agent,
      conn.remote_ip,
      sanitize(params)
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

  defp verify_secret(identity, encoded_token, conn) do
    context = auth_context(conn, :browser)
    Domain.Auth.Adapters.Email.verify_secret(identity, context, encoded_token)
  end

  defp check_admin(
         %Auth.Identity{actor: %Domain.Actors.Actor{type: :account_admin_user}},
         _context_type
       ),
       do: :ok

  defp check_admin(%Auth.Identity{actor: %Domain.Actors.Actor{type: :account_user}}, :client),
    do: :ok

  defp check_admin(_identity, _context_type), do: {:error, :not_admin}

  defp create_token(conn, identity, params) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    type = context_type(params)
    headers = conn.req_headers
    context = Domain.Auth.Context.build(remote_ip, user_agent, headers, type)

    attrs = %{
      type: context.type,
      secret_nonce: params["nonce"],
      secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
      account_id: identity.account_id,
      actor_id: identity.actor_id,
      identity_id: identity.id,
      expires_at: DateTime.add(DateTime.utc_now(), @session_token_hours, :hour),
      created_by_user_agent: context.user_agent,
      created_by_remote_ip: context.remote_ip
    }

    with {:ok, token} <- Tokens.create_token(attrs) do
      {:ok, Tokens.encode_fragment!(token)}
    end
  end

  # Context: :browser
  # Store session cookie and redirect to portal or redirect_to parameter
  defp signed_in(conn, :browser, account, _identity, token, params) do
    conn
    |> Web.Session.Cookie.put_account_cookie(account.id, token)
    |> Redirector.portal_signed_in(account, params)
  end

  # Context: :client
  # Store a cookie and redirect to client handler which redirects to the final URL based on platform
  defp signed_in(conn, :client, _account, identity, token, params) do
    Redirector.client_signed_in(
      conn,
      identity.actor.name,
      identity.provider_identifier,
      token,
      params["state"]
    )
  end

  defp put_auth_state(conn, provider_id, state) do
    key = state_cookie_key(provider_id)
    value = :erlang.term_to_binary(state)
    put_resp_cookie(conn, key, value, @cookie_options)
  end

  defp maybe_put_resent_flash(%Plug.Conn{state: :unset} = conn, %{"resend" => "true"}),
    do: put_flash(conn, :info, "Email was resent.")

  defp maybe_put_resent_flash(conn, _params),
    do: conn

  defp state_cookie_key(provider_id) do
    @cookie_key <> "_" <> provider_id
  end

  defp handle_error(conn, {:error, :not_found}, params) do
    error = "You may not use this method to sign in."
    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, :not_admin}, params) do
    error = "This action requires admin privileges."
    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, :invalid_secret}, params) do
    conn = fetch_cookies(conn, signed: [@cookie_key])

    signed_idp_id =
      Plug.Crypto.sign(
        conn.secret_key_base,
        "signed_idp_id",
        Map.get(conn.cookies[@cookie_key] || %{}, "idp_id", "")
      )

    redirect_params =
      params
      |> sanitize()
      |> Map.put("signed_idp_id", signed_idp_id)

    auth_provider_id = params["auth_provider_id"]
    error = "The sign in token is invalid or expired."

    path =
      ~p"/#{params["account_id_or_slug"]}/sign_in/email_otp/#{auth_provider_id}?#{redirect_params}"

    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, :error, params) do
    error = "The sign in token is missing or expired. Please try again."
    path = ~p"/#{params["account_id_or_slug"]}?#{sanitize(params)}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, :invalid_params, params) do
    error = "Invalid request."
    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, error, params) do
    Logger.warning("Email OTP sign in error: #{inspect(error)}")
    error = "An unexpected error occurred while signing you in. Please try again."
    path = ~p"/#{params["account_id_or_slug"]}?#{sanitize(params)}"
    redirect_for_error(conn, error, path)
  end

  defp redirect_for_error(conn, error, path) do
    conn
    |> put_flash(:error, error)
    |> redirect(to: path)
    |> halt()
  end

  defp sanitize(params) do
    Map.take(params, ["as", "redirect_to", "state", "nonce"])
  end

  defp context_type(%{"as" => "client"}), do: :client
  defp context_type(_), do: :browser

  defp auth_context(conn, context_type) do
    remote_ip = conn.remote_ip
    user_agent = conn.assigns[:user_agent]
    headers = conn.req_headers

    Domain.Auth.Context.build(remote_ip, user_agent, headers, context_type)
  end
end
