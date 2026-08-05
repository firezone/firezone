defmodule PortalWeb.SupportController do
  @moduledoc """
  Controller for the Firezone Support sign-in flow.

  Support engineers sign in with their whitelisted email, a one-time code sent
  to that email, and a WebAuthn passkey assertion. The flow only exists while
  the account has an active Firezone Support auth provider and 404s otherwise.
  """
  use PortalWeb, :controller

  alias Portal.Authentication
  alias __MODULE__.Database
  alias PortalWeb.Session.Redirector

  require Logger

  @constant_execution_time Application.compile_env(:portal, :constant_execution_time, 3000)

  def sign_in(
        conn,
        %{"account_id_or_slug" => account_id_or_slug, "email" => %{"email" => email}} = params
      )
      when is_binary(email) do
    {account, _provider} = fetch_account_and_active_provider!(account_id_or_slug)

    conn = send_support_otp(conn, account, Portal.SupportAdmin.normalize_email(email), params)

    conn
    |> maybe_put_resent_flash(params)
    |> redirect(to: ~p"/#{account_id_or_slug}/support/verify?#{sanitize(params)}")
  end

  def sign_in(conn, params) do
    Logger.info("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  def verify_otp(conn, %{"secret" => entered_code} = params) do
    %{"account_id_or_slug" => account_id_or_slug} = params
    {account, _provider} = fetch_account_and_active_provider!(account_id_or_slug)

    result =
      Portal.Timing.execute_with_constant_time(
        fn -> do_verify_otp(conn, account, String.downcase(entered_code)) end,
        @constant_execution_time
      )

    case result do
      {:ok, support_admin} ->
        challenge =
          Portal.Crypto.WebAuthn.authentication_challenge(
            support_admin.passkey_credential_id,
            Portal.Crypto.WebAuthn.decode_cose_key(support_admin.passkey_public_key)
          )

        :ok = Authentication.create_support_ceremony(support_admin, challenge.bytes)

        cookie = %PortalWeb.Cookie.Support{
          account_id: account.id,
          email: support_admin.email,
          stage: :passkey,
          challenge: challenge
        }

        conn
        |> PortalWeb.Cookie.Support.put(cookie)
        |> redirect(to: ~p"/#{account_id_or_slug}/support/passkey?#{sanitize(params)}")

      error ->
        handle_error(conn, error, params)
    end
  end

  def verify_otp(conn, params) do
    Logger.info("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  def complete(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "credential_id" => credential_id,
          "authenticator_data" => authenticator_data,
          "signature" => signature,
          "client_data_json" => client_data_json
        } = params
      ) do
    {account, provider} = fetch_account_and_active_provider!(account_id_or_slug)
    context_type = context_type(params)

    with {:ok, cookie} <- fetch_stage(conn, account, :passkey),
         {:ok, credential_id} <- Base.url_decode64(credential_id, padding: false),
         {:ok, authenticator_data} <- Base.url_decode64(authenticator_data, padding: false),
         {:ok, signature} <- Base.url_decode64(signature, padding: false),
         {:ok, client_data_json} <- Base.url_decode64(client_data_json, padding: false),
         {:ok, auth_data} <-
           Portal.Crypto.WebAuthn.verify_authentication(
             credential_id,
             authenticator_data,
             signature,
             client_data_json,
             cookie.challenge
           ),
         {:ok, support_admin} <- Database.fetch_support_admin_by_email(cookie.email),
         :ok <- check_credential(support_admin, credential_id, auth_data.sign_count),
         :ok <- Authentication.consume_support_ceremony(cookie.email, cookie.challenge.bytes),
         {:ok, actor} <- Database.upsert_support_actor(account, support_admin.email),
         {:ok, session_or_token} <- create_session_or_token(conn, actor, provider, params) do
      if auth_data.sign_count > 0 do
        :ok = Authentication.update_support_admin_sign_count(support_admin, auth_data.sign_count)
      end

      conn = PortalWeb.Cookie.Support.delete(conn)
      :ok = Portal.Mailer.RateLimiter.reset_rate_limit({:support_sign_in_otp, cookie.email})
      signed_in(conn, context_type, account, actor, session_or_token, params)
    else
      error ->
        handle_error(conn, error, params)
    end
  end

  def complete(conn, params) do
    Logger.info("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  defp fetch_account_and_active_provider!(account_id_or_slug) do
    with {:ok, account} <- Database.fetch_account_by_id_or_slug(account_id_or_slug),
         {:ok, provider} <- Database.fetch_active_support_provider(account) do
      {account, provider}
    else
      _error ->
        raise PortalWeb.LiveErrors.NotFoundError
    end
  end

  # The rate-limit slot is reserved before the OTP is rotated so that
  # over-limit requests cannot silently invalidate an already-delivered code,
  # and the response is identical for known, unknown, and rate-limited emails
  defp send_support_otp(conn, account, email, params) do
    Portal.Timing.execute_with_constant_time(
      fn ->
        {:support_sign_in_otp, email}
        |> Portal.Mailer.RateLimiter.rate_limit(3, :timer.minutes(5), fn ->
          create_and_send_otp(account, email, params)
        end)
        |> case do
          {:ok, {:ok, _metadata}} ->
            :ok

          {:error, :rate_limited} ->
            Logger.info("Support sign-in rate limited", account_slug: account.slug)
            :error

          other ->
            Logger.info("Support sign-in OTP not sent",
              account_slug: account.slug,
              error: inspect(other)
            )

            :error
        end
      end,
      @constant_execution_time
    )

    cookie = %PortalWeb.Cookie.Support{account_id: account.id, email: email, stage: :otp}
    PortalWeb.Cookie.Support.put(conn, cookie)
  end

  defp create_and_send_otp(account, email, _params) do
    with {:ok, support_admin} <- Authentication.create_support_admin_otp(email) do
      Portal.Mailer.SupportEmail.sign_in_otp_email(
        support_admin.email,
        support_admin.otp_code,
        account
      )
      |> Portal.Mailer.deliver()
    end
  end

  defp do_verify_otp(conn, account, entered_code) do
    with {:ok, cookie} <- fetch_stage(conn, account, :otp) do
      Authentication.verify_support_admin_otp(cookie.email, entered_code)
    end
  end

  defp fetch_stage(conn, account, stage) do
    case PortalWeb.Cookie.Support.fetch(conn) do
      %PortalWeb.Cookie.Support{stage: ^stage, account_id: account_id} = cookie
      when account_id == account.id ->
        {:ok, cookie}

      _other ->
        :error
    end
  end

  defp check_credential(support_admin, credential_id, sign_count) do
    cond do
      support_admin.passkey_credential_id != credential_id ->
        {:error, :credential_mismatch}

      sign_count > 0 and support_admin.passkey_sign_count > 0 and
          sign_count <= support_admin.passkey_sign_count ->
        {:error, :sign_count_regression}

      true ->
        :ok
    end
  end

  defp create_session_or_token(conn, actor, provider, params) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    type = context_type(params)
    headers = conn.req_headers
    context = Portal.Authentication.Context.build(remote_ip, user_agent, headers, type)

    expires_at = provider.expires_at

    case type do
      :portal ->
        Authentication.create_portal_session(actor, provider.id, context, expires_at)

      :gui_client ->
        Authentication.create_interactive_client_token(%{
          type: :client,
          secret_nonce: params["nonce"],
          secret_fragment: Portal.Crypto.random_token(32, encoder: :hex32),
          account_id: actor.account_id,
          actor_id: actor.id,
          auth_provider_id: provider.id,
          expires_at: expires_at
        })

      :headless_client ->
        Authentication.create_interactive_client_token(%{
          type: :client,
          secret_nonce: "",
          secret_fragment: Portal.Crypto.random_token(32, encoder: :hex32),
          account_id: actor.account_id,
          actor_id: actor.id,
          auth_provider_id: provider.id,
          expires_at: expires_at
        })
    end
  end

  defp signed_in(conn, :portal, account, actor, session, params) do
    conn
    |> PortalWeb.Cookie.Session.put(account.id, %PortalWeb.Cookie.Session{session_id: session.id})
    |> Redirector.portal_signed_in(account, params, actor)
  end

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

  defp maybe_put_resent_flash(conn, _params), do: conn

  defp handle_error(conn, {:error, :invalid_code}, params) do
    error = "The sign in code is invalid or expired."
    path = ~p"/#{params["account_id_or_slug"]}/support/verify?#{sanitize(params)}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, :invalid_ceremony}, params) do
    error = "Your sign-in session is missing or expired. Please try again."
    path = ~p"/#{params["account_id_or_slug"]}/support?#{sanitize(params)}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, :error, params) do
    error = "Your sign-in session is missing or expired. Please try again."
    path = ~p"/#{params["account_id_or_slug"]}/support?#{sanitize(params)}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, :invalid_params, params) do
    error = "Invalid request."
    path = ~p"/#{params["account_id_or_slug"]}/support"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, error, params) do
    Logger.info("Support sign in error", error: inspect(error))
    error = "Passkey verification failed. Please try again."
    path = ~p"/#{params["account_id_or_slug"]}/support/passkey?#{sanitize(params)}"
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
  defp context_type(_params), do: :portal

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.{Account, Actor, FirezoneSupport, SupportAdmin}

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

    def fetch_active_support_provider(account) do
      from(p in FirezoneSupport.AuthProvider,
        where: p.account_id == ^account.id,
        where: p.expires_at > ^DateTime.utc_now()
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> handle_nil()
    end

    def fetch_support_admin_by_email(email) do
      from(sa in SupportAdmin,
        where: sa.email == ^email,
        where: not is_nil(sa.passkey_registered_at)
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> handle_nil()
    end

    def upsert_support_actor(account, support_admin_email) do
      case fetch_support_actor(account, support_admin_email) do
        nil ->
          insert_support_actor(account, support_admin_email)

        actor ->
          ensure_enabled(actor)
      end
    end

    defp insert_support_actor(account, email) do
      {:ok, _actor} =
        %Actor{
          account_id: account.id,
          type: :firezone_support,
          name: "Firezone Support",
          email: email,
          allow_email_otp_sign_in: false
        }
        |> then(&Safe.insert(Portal.Repo, &1, on_conflict: :nothing))

      # Refetch to survive a concurrent insert racing on the unique email index
      case fetch_support_actor(account, email) do
        nil -> {:error, :not_found}
        actor -> ensure_enabled(actor)
      end
    end

    defp fetch_support_actor(account, email) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: a.email == ^email
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    defp ensure_enabled(%Actor{is_disabled: true} = actor) do
      from(a in Actor,
        where: a.account_id == ^actor.account_id,
        where: a.id == ^actor.id,
        update: [set: [is_disabled: false]]
      )
      |> Safe.unscoped()
      |> Safe.update_all([])

      {:ok, %{actor | is_disabled: false}}
    end

    defp ensure_enabled(%Actor{} = actor), do: {:ok, actor}

    defp handle_nil(nil), do: {:error, :not_found}
    defp handle_nil(result), do: {:ok, result}
  end
end
