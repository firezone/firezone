defmodule PortalWeb.EmailOTPController do
  @moduledoc """
  Controller for handling email OTP authentication.
  """
  use PortalWeb, :controller

  alias Portal.Auth
  alias __MODULE__.Database
  alias PortalWeb.Session.Redirector

  require Logger

  @constant_execution_time Application.compile_env(:portal, :constant_execution_time, 2000)

  @spec sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_in(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "auth_provider_id" => auth_provider_id,
          "email" => %{"email" => email}
        } = params
      )
      when is_binary(email) do
    with {:ok, account} <- Database.fetch_account_by_id_or_slug(account_id_or_slug),
         {:ok, _provider} <- Database.fetch_provider_by_id(account, auth_provider_id) do
      conn = maybe_send_email_otp(conn, account, email, params, auth_provider_id)

      redirect_params = sanitize(params)

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
    Logger.info("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  @spec verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify(conn, %{"secret" => entered_code} = params) do
    result =
      execute_with_constant_time(
        fn -> do_verify(conn, params, String.downcase(entered_code)) end,
        @constant_execution_time
      )

    handle_verify_result(conn, result, params)
  end

  def verify(conn, params) do
    Logger.info("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  defp do_verify(conn, params, entered_code) do
    %{"account_id_or_slug" => account_id_or_slug, "auth_provider_id" => auth_provider_id} = params
    context_type = context_type(params)

    with {:ok, actor_id, passcode_id, email} <- fetch_state(conn),
         {:ok, account} <- Database.fetch_account_by_id_or_slug(account_id_or_slug),
         {:ok, provider} <- Database.fetch_provider_by_id(account, auth_provider_id),
         {:ok, passcode} <-
           Auth.verify_one_time_passcode(account.id, actor_id, passcode_id, entered_code),
         :ok <- check_admin(passcode.actor, context_type),
         {:ok, session_or_token} <-
           create_session_or_token(conn, passcode.actor, provider, params) do
      {:ok,
       %{
         account: account,
         actor: passcode.actor,
         session_or_token: session_or_token,
         email: email
       }}
    end
  end

  defp handle_verify_result(conn, {:ok, result}, params) do
    context_type = context_type(params)
    conn = PortalWeb.Cookie.EmailOTP.delete(conn)
    :ok = Portal.Mailer.RateLimiter.reset_rate_limit({:sign_in_link, result.email})
    signed_in(conn, context_type, result.account, result.actor, result.session_or_token, params)
  end

  defp handle_verify_result(conn, error, params) do
    handle_error(conn, error, params)
  end

  defp fetch_state(conn) do
    case PortalWeb.Cookie.EmailOTP.fetch(conn) do
      %PortalWeb.Cookie.EmailOTP{actor_id: actor_id, passcode_id: passcode_id, email: email} ->
        {:ok, actor_id, passcode_id, email}

      nil ->
        :error
    end
  end

  defp maybe_send_email_otp(conn, account, email, params, auth_provider_id) do
    {actor_id, passcode_id, error} =
      execute_with_constant_time(
        fn ->
          with {:ok, actor} <- Database.fetch_actor_by_email(account, email),
               {:ok, otp} <- Auth.create_one_time_passcode(account, actor),
               {:ok, _} <- send_email_otp(conn, actor, otp.code, auth_provider_id, params) do
            {actor.id, otp.id, nil}
          else
            {:error, :rate_limited} ->
              {Ecto.UUID.generate(), Ecto.UUID.generate(), :rate_limited}

            _ ->
              # Generate dummy IDs to prevent oracle attacks
              {Ecto.UUID.generate(), Ecto.UUID.generate(), nil}
          end
        end,
        @constant_execution_time
      )

    cookie = %PortalWeb.Cookie.EmailOTP{
      actor_id: actor_id,
      passcode_id: passcode_id,
      email: email
    }

    conn = PortalWeb.Cookie.EmailOTP.put(conn, cookie)

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

  defp send_email_otp(conn, actor, code, auth_provider_id, params) do
    Portal.Mailer.AuthEmail.sign_in_link_email(
      actor,
      DateTime.utc_now(),
      auth_provider_id,
      code,
      conn.assigns.user_agent,
      conn.remote_ip,
      sanitize(params)
    )
    |> Portal.Mailer.deliver_with_rate_limit(
      rate_limit_key: {:sign_in_link, actor.email},
      rate_limit: 3,
      rate_limit_interval: :timer.minutes(5)
    )
  end

  defp check_admin(%Portal.Actor{type: :account_admin_user}, _context_type), do: :ok

  defp check_admin(%Portal.Actor{type: :account_user}, t)
       when t in [:gui_client, :headless_client],
       do: :ok

  defp check_admin(_actor, _context_type), do: {:error, :not_admin}

  defp create_session_or_token(conn, actor, provider, params) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    type = context_type(params)
    headers = conn.req_headers
    context = Portal.Auth.Context.build(remote_ip, user_agent, headers, type)

    # Get the provider schema module to access default values
    schema = provider.__struct__

    # Determine session lifetime based on context type
    session_lifetime_secs =
      case type do
        :gui_client ->
          provider.client_session_lifetime_secs || schema.default_client_session_lifetime_secs()

        :headless_client ->
          provider.client_session_lifetime_secs || schema.default_client_session_lifetime_secs()

        :portal ->
          provider.portal_session_lifetime_secs || schema.default_portal_session_lifetime_secs()
      end

    expires_at = DateTime.add(DateTime.utc_now(), session_lifetime_secs, :second)

    case type do
      :portal ->
        Auth.create_portal_session(
          actor,
          provider.id,
          context,
          expires_at
        )

      :gui_client ->
        attrs = %{
          type: :client,
          secret_nonce: params["nonce"],
          secret_fragment: Portal.Crypto.random_token(32, encoder: :hex32),
          account_id: actor.account_id,
          actor_id: actor.id,
          auth_provider_id: provider.id,
          expires_at: expires_at
        }

        Auth.create_gui_client_token(attrs)

      :headless_client ->
        attrs = %{
          type: :client,
          secret_nonce: "",
          secret_fragment: Portal.Crypto.random_token(32, encoder: :hex32),
          account_id: actor.account_id,
          actor_id: actor.id,
          auth_provider_id: provider.id,
          expires_at: expires_at
        }

        Auth.create_gui_client_token(attrs)
    end
  end

  # Context: :portal
  # Store session cookie and redirect to portal or redirect_to parameter
  defp signed_in(conn, :portal, account, _actor, session, params) do
    conn
    |> PortalWeb.Cookie.Session.put(account.id, %PortalWeb.Cookie.Session{session_id: session.id})
    |> Redirector.portal_signed_in(account, params)
  end

  # Context: :gui_client
  # Store a cookie and redirect to client handler which redirects to the final URL based on platform
  defp signed_in(conn, :gui_client, account, actor, token, params) do
    Redirector.gui_client_signed_in(
      conn,
      account,
      actor.name,
      actor.email,
      token,
      params["state"]
    )
  end

  # Context: :headless_client
  # Show the token to the user to copy manually
  defp signed_in(conn, :headless_client, account, actor, token, params) do
    Redirector.headless_client_signed_in(
      conn,
      account,
      actor.name,
      token,
      params["state"]
    )
  end

  defp maybe_put_resent_flash(%Plug.Conn{} = conn, %{"resend" => "true"}),
    do: put_flash(conn, :success_inline, "Email was resent.")

  defp maybe_put_resent_flash(conn, _params),
    do: conn

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

  defp handle_error(conn, {:error, :invalid_code}, params) do
    auth_provider_id = params["auth_provider_id"]
    redirect_params = sanitize(params)
    error = "The sign in code is invalid or expired."

    path =
      ~p"/#{params["account_id_or_slug"]}/sign_in/email_otp/#{auth_provider_id}?#{redirect_params}"

    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, :error, params) do
    error = "The sign in code is missing or expired. Please try again."
    path = ~p"/#{params["account_id_or_slug"]}?#{sanitize(params)}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, :invalid_params, params) do
    error = "Invalid request."
    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, error, params) do
    Logger.info("Email OTP sign in error", error: error)
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

  defp context_type(%{"as" => "client"}), do: :gui_client
  defp context_type(%{"as" => "gui-client"}), do: :gui_client
  defp context_type(%{"as" => "headless-client"}), do: :headless_client
  defp context_type(_), do: :portal

  # Executes a callback in constant time to prevent timing attacks.
  # If execution is faster than constant_time, sleeps for the remainder.
  defp execute_with_constant_time(callback, constant_time) do
    start_time = System.monotonic_time(:millisecond)
    result = callback.()
    end_time = System.monotonic_time(:millisecond)

    elapsed_time = end_time - start_time
    remaining_time = max(0, constant_time - elapsed_time)

    if remaining_time > 0 do
      :timer.sleep(remaining_time)
    else
      log_constant_time_exceeded(constant_time, elapsed_time)
    end

    result
  end

  if Mix.env() in [:dev, :test] do
    defp log_constant_time_exceeded(_constant_time, _elapsed_time), do: :ok
  else
    defp log_constant_time_exceeded(constant_time, elapsed_time) do
      Logger.error("Execution took longer than the given constant time",
        constant_time: constant_time,
        elapsed_time: elapsed_time
      )
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.{Account, Actor, EmailOTP}

    def fetch_account_by_id_or_slug(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query
      |> Safe.unscoped()
      |> Safe.one()
      |> handle_nil()
    end

    def fetch_provider_by_id(account, id) do
      from(p in EmailOTP.AuthProvider,
        where: p.account_id == ^account.id and p.id == ^id and not p.is_disabled
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> handle_nil()
    end

    def fetch_actor_by_email(account, email) do
      from(a in Actor,
        where:
          a.email == ^email and
            a.account_id == ^account.id and
            is_nil(a.disabled_at) and
            a.allow_email_otp_sign_in == true
      )
      |> preload(:account)
      |> Safe.unscoped()
      |> Safe.one()
      |> handle_nil()
    end

    defp handle_nil(nil), do: {:error, :not_found}
    defp handle_nil(result), do: {:ok, result}
  end
end
