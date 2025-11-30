defmodule Web.EmailOTPController do
  @moduledoc """
  Controller for handling email OTP authentication.
  """
  use Web, :controller

  alias Domain.{
    Actor,
    EmailOTP,
    Safe,
    Tokens
  }

  alias __MODULE__.DB
  alias Web.Session.Redirector

  require Logger

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
    email = email_params["email"]

    with %Domain.Account{} = account <- DB.get_account_by_id_or_slug(account_id_or_slug),
         %EmailOTP.AuthProvider{} <- fetch_provider(account, auth_provider_id) do
      conn = maybe_send_email_otp(conn, account, email, params, auth_provider_id)

      signed_email =
        Plug.Crypto.sign(conn.secret_key_base, "signed_email", email)

      redirect_params =
        params
        |> sanitize()
        |> Map.put("signed_email", signed_email)

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

    with {:ok, cookie_binary} <- Map.fetch(conn.cookies, cookie_key),
         {fragment, email, _stored_params} <- :erlang.binary_to_term(cookie_binary),
         conn = delete_resp_cookie(conn, cookie_key),
         %Domain.Account{} = account <- DB.get_account_by_id_or_slug(account_id_or_slug),
         %EmailOTP.AuthProvider{} = provider <- fetch_provider(account, auth_provider_id),
         %Domain.Actor{} = actor <- fetch_actor(account, email),
         :ok <- check_admin(actor, context_type),
         secret = String.downcase(nonce) <> fragment,
         {:ok, actor, _expires_at} <- verify_secret(actor, secret, conn),
         {:ok, token} <- create_token(conn, actor, provider, params) do
      :ok = Domain.Mailer.RateLimiter.reset_rate_limit({:sign_in_link, actor.id})
      signed_in(conn, context_type, account, actor, token, params)
    else
      error ->
        handle_error(conn, error, params)
    end
  end

  def verify(conn, params) do
    Logger.warning("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  defp maybe_send_email_otp(conn, account, email, params, auth_provider_id) do
    context_type = context_type(params)
    context = auth_context(conn, context_type)

    {fragment, error} =
      Web.Auth.execute_with_constant_time(
        fn ->
          with %Domain.Actor{} = actor <- fetch_actor(account, email),
               {:ok, actor, fragment, nonce} <- request_sign_in_token(actor, context),
               {:ok, fragment} <-
                 send_email_otp(conn, actor, fragment, nonce, auth_provider_id, params) do
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
                  expires_at: DateTime.utc_now()
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
                  expires_at: DateTime.utc_now()
                })

              {fake_fragment, nil}
          end
        end,
        @constant_execution_time
      )

    conn = put_auth_state(conn, auth_provider_id, {fragment, email, sanitize(params)})

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
    |> Safe.unscoped()
    |> Safe.one()
  end

  defp fetch_actor(account, email) do
    import Ecto.Query

    # Fetch actor by email and account_id, ensuring the actor is not disabled
    from(a in Actor,
      where: a.email == ^email and a.account_id == ^account.id and is_nil(a.disabled_at),
      preload: [:account]
    )
    |> Safe.unscoped()
    |> Safe.one()
  end

  defp request_sign_in_token(actor, _context) do
    # Token expiration: 30 minutes
    sign_in_token_expiration_seconds = 30 * 60
    # Max attempts: 3
    sign_in_token_max_attempts = 3

    nonce = String.downcase(Domain.Crypto.random_token(5, encoder: :user_friendly))
    expires_at = DateTime.utc_now() |> DateTime.add(sign_in_token_expiration_seconds, :second)

    # Delete all existing email tokens for this actor
    {:ok, _count} = delete_all_email_tokens_for_actor(actor)

    {:ok, token} =
      Tokens.create_token(%{
        type: :email,
        secret_fragment: Domain.Crypto.random_token(27),
        secret_nonce: nonce,
        account_id: actor.account_id,
        actor_id: actor.id,
        remaining_attempts: sign_in_token_max_attempts,
        expires_at: expires_at
      })

    fragment = Domain.Tokens.encode_fragment!(token)

    {:ok, actor, fragment, nonce}
  end

  defp delete_all_email_tokens_for_actor(actor) do
    import Ecto.Query

    query =
      from(t in Domain.Tokens.Token,
        where: t.type == :email and t.account_id == ^actor.account_id and t.actor_id == ^actor.id
      )

    {num_deleted, _} = query |> Safe.unscoped() |> Safe.delete_all()

    {:ok, num_deleted}
  end

  defp send_email_otp(conn, actor, fragment, nonce, auth_provider_id, params) do
    Domain.Mailer.AuthEmail.sign_in_link_email(
      actor,
      DateTime.utc_now(),
      auth_provider_id,
      nonce,
      conn.assigns.user_agent,
      conn.remote_ip,
      sanitize(params)
    )
    |> Domain.Mailer.deliver_with_rate_limit(
      rate_limit_key: {:sign_in_link, actor.id},
      rate_limit: 3,
      rate_limit_interval: :timer.minutes(5)
    )
    |> case do
      {:ok, _} -> {:ok, fragment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_secret(actor, encoded_token, conn) do
    context = auth_context(conn, :browser)

    with {:ok, token} <- Tokens.use_token(encoded_token, %{context | type: :email}),
         true <- token.actor_id == actor.id do
      {:ok, _count} = delete_all_email_tokens_for_actor(actor)
      {:ok, actor, nil}
    else
      {:error, :invalid_or_expired_token} -> {:error, :invalid_secret}
      false -> {:error, :invalid_secret}
    end
  end

  defp check_admin(%Domain.Actor{type: :account_admin_user}, _context_type), do: :ok
  defp check_admin(%Domain.Actor{type: :account_user}, :client), do: :ok
  defp check_admin(_actor, _context_type), do: {:error, :not_admin}

  defp create_token(conn, actor, provider, params) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    type = context_type(params)
    headers = conn.req_headers
    context = Domain.Auth.Context.build(remote_ip, user_agent, headers, type)

    # Get the provider schema module to access default values
    schema = provider.__struct__

    # Determine session lifetime based on context type
    session_lifetime_secs =
      case type do
        :client ->
          provider.client_session_lifetime_secs || schema.default_client_session_lifetime_secs()

        :browser ->
          provider.portal_session_lifetime_secs || schema.default_portal_session_lifetime_secs()
      end

    attrs = %{
      type: context.type,
      secret_nonce: params["nonce"],
      secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
      account_id: actor.account_id,
      actor_id: actor.id,
      auth_provider_id: provider.id,
      expires_at: DateTime.add(DateTime.utc_now(), session_lifetime_secs, :second)
    }

    with {:ok, token} <- Tokens.create_token(attrs) do
      {:ok, Domain.Tokens.encode_fragment!(token)}
    end
  end

  # Context: :browser
  # Store session cookie and redirect to portal or redirect_to parameter
  defp signed_in(conn, :browser, account, _actor, token, params) do
    conn
    |> Web.Session.Cookie.put_account_cookie(account.id, token)
    |> Redirector.portal_signed_in(account, params)
  end

  # Context: :client
  # Store a cookie and redirect to client handler which redirects to the final URL based on platform
  defp signed_in(conn, :client, _account, actor, token, params) do
    Redirector.client_signed_in(
      conn,
      actor.name,
      actor.email,
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
    do: put_flash(conn, :success_inline, "Email was resent.")

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
    cookie_key = state_cookie_key(params["auth_provider_id"])
    conn = fetch_cookies(conn, signed: [cookie_key])

    {_fragment, email, _stored_params} =
      case Map.get(conn.cookies, cookie_key) do
        binary when is_binary(binary) -> :erlang.binary_to_term(binary)
        _ -> {"", "", %{}}
      end

    signed_email =
      Plug.Crypto.sign(
        conn.secret_key_base,
        "signed_email",
        email
      )

    redirect_params =
      params
      |> sanitize()
      |> Map.put("signed_email", signed_email)

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

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Account

    def get_account_by_id_or_slug(id_or_slug) do
      from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug)
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
