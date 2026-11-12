defmodule PortalWeb.UserpassController do
  @moduledoc """
  Controller for handling user/password authentication.
  """
  use PortalWeb, :controller

  alias Portal.Userpass

  alias __MODULE__.Database
  alias PortalWeb.Session.Redirector

  require Logger

  # Password attempts are throttled per account and submitted email. Keying on
  # the submitted email rather than the actor throttles unknown emails exactly
  # like known ones, so the throttle itself does not reveal which emails exist.
  # The bucket refills instead of locking, so an attacker can only delay a
  # legitimate user, not lock them out. Every attempt is charged. Hammer
  # refills whole tokens per second; charging 60 tokens per attempt and
  # refilling 1/s expresses one attempt per minute after a burst of 10.
  @rate_limit_cost 60
  @rate_limit_refill_rate 1
  @rate_limit_capacity 10 * @rate_limit_cost

  @spec sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_in(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "auth_provider_id" => auth_provider_id,
          "userpass" => %{"idp_id" => email, "secret" => password}
        } = params
      )
      when is_binary(email) and is_binary(password) do
    context_type = context_type(params)

    with %Portal.Account{} = account <- PortalWeb.Accounts.get_by_id_or_slug(account_id_or_slug),
         %Userpass.AuthProvider{} = provider <- fetch_provider(account, auth_provider_id),
         false <- client_sign_in_restricted?(account, context_type),
         :ok <- check_rate_limit(account, email),
         # Nothing that depends on whether the email matches an actor may run
         # before the password is verified, or the response becomes an oracle.
         {:ok, actor} <- verify_password(fetch_actor(account, email), password),
         false <- client_seat_restricted?(account, actor, context_type),
         :ok <- check_admin(actor, context_type),
         :ok <- Portal.AuthProvider.validate_context(provider, context_type),
         {:ok, session_or_token} <- create_session_or_token(conn, actor, provider, params) do
      conn = PortalWeb.Cookie.LastUsedProvider.put(conn, provider.id)
      signed_in(conn, context_type, account, actor, session_or_token, params)
    else
      error -> handle_error(conn, error, params)
    end
  end

  def sign_in(conn, params) do
    Logger.warning("Invalid request parameters", params: Map.drop(params, ["userpass"]))
    handle_error(conn, :invalid_params, params)
  end

  defp verify_password(%Portal.Actor{password_hash: password_hash} = actor, password) do
    if Portal.Crypto.equal?(:argon2, password, password_hash) do
      {:ok, actor}
    else
      {:error, :invalid_secret}
    end
  end

  defp verify_password(nil, _password) do
    Portal.Crypto.equal?(:argon2, nil, nil)
    {:error, :invalid_secret}
  end

  defp check_rate_limit(%Portal.Account{id: account_id}, email) do
    case PortalWeb.RateLimit.hit(
           rate_limit_key(account_id, email),
           @rate_limit_refill_rate,
           @rate_limit_capacity,
           @rate_limit_cost
         ) do
      {:allow, _remaining} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limit, retry_after_ms}}
    end
  end

  defp rate_limit_key(account_id, email) do
    digest =
      :crypto.hash(:sha256, email |> String.trim() |> String.downcase())
      |> Base.encode16(case: :lower)

    "userpass_sign_in:#{account_id}:#{digest}"
  end

  defp check_admin(%Portal.Actor{type: :account_admin_user}, _context_type), do: :ok

  defp check_admin(%Portal.Actor{type: :account_user}, t)
       when t in [:gui_client, :headless_client],
       do: :ok

  defp check_admin(_actor, _context_type), do: {:error, :not_admin}

  defp client_sign_in_restricted?(account, context_type)
       when context_type in [:gui_client, :headless_client] do
    Portal.Billing.client_sign_in_restricted?(account)
  end

  defp client_sign_in_restricted?(_account, _context_type), do: false

  defp client_seat_restricted?(account, actor, context_type)
       when context_type in [:gui_client, :headless_client] do
    Portal.Billing.client_seat_restricted?(account, actor.id)
  end

  defp client_seat_restricted?(_account, _actor, _context_type), do: false

  defp create_session_or_token(conn, actor, provider, params) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    type = context_type(params)
    headers = conn.req_headers
    context = Portal.Authentication.Context.build(remote_ip, user_agent, headers, type)

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

        :oauth ->
          PortalWeb.Cookie.OAuthSession.lifetime_secs()
      end

    expires_at = DateTime.add(DateTime.utc_now(), session_lifetime_secs, :second)

    case type do
      # Approving an app connection gets a session of its own, kept in its own
      # cookie and expiring quickly, so it neither grants portal access nor is
      # satisfied by portal access.
      t when t in [:portal, :oauth] ->
        Portal.Authentication.create_portal_session(
          actor,
          provider.id,
          context,
          expires_at
        )

      :gui_client ->
        attrs = %{
          secret_nonce: params["nonce"],
          account_id: actor.account_id,
          actor_id: actor.id,
          auth_provider_id: provider.id,
          expires_at: expires_at
        }

        Portal.Authentication.create_interactive_client_token(attrs)

      :headless_client ->
        attrs = %{
          secret_nonce: "",
          account_id: actor.account_id,
          actor_id: actor.id,
          auth_provider_id: provider.id,
          expires_at: expires_at
        }

        Portal.Authentication.create_interactive_client_token(attrs)
    end
  end

  # Context: :portal
  # Store session cookie and redirect to portal or redirect_to parameter
  defp signed_in(conn, :portal, account, actor, session, params) do
    conn
    |> PortalWeb.Cookie.Session.put(account.id, %PortalWeb.Cookie.Session{session_id: session.id})
    |> Redirector.portal_signed_in(account, params, actor)
  end

  # Context: :oauth
  # Store the approval-flow cookie only, and go back to the pending request.
  defp signed_in(conn, :oauth, account, actor, session, params) do
    conn
    |> PortalWeb.Cookie.OAuthSession.put(account.id, %PortalWeb.Cookie.OAuthSession{
      session_id: session.id
    })
    |> Phoenix.Controller.redirect(
      to: Redirector.sanitize_redirect_to(account, params["redirect_to"], actor)
    )
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

  defp fetch_provider(account, id) do
    Database.get_provider(account, id)
  end

  defp fetch_actor(account, email) do
    Database.get_actor_by_email(account, email)
  end

  defp handle_error(conn, {:error, :invalid_secret}, _params) do
    error = "Invalid username or password."
    path = conn.request_path
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, {:rate_limit, _retry_after_ms}}, _params) do
    error = "Too many sign-in attempts. Please try again in a minute."
    path = conn.request_path
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, :not_admin}, params) do
    error = "This action requires admin privileges."
    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, :invalid_context}, params) do
    error = "This authentication method is not available for your sign-in context."
    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, true, params) do
    error =
      "This account is temporarily suspended from client authentication " <>
        "due to exceeding billing limits. Please contact your administrator to add more seats."

    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, :invalid_params, params) do
    error = "Invalid request."
    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, error, params) do
    Logger.warning("Userpass sign in error: #{inspect(error)}")
    error = "Invalid username or password."
    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp redirect_for_error(conn, error, path) do
    conn
    |> put_flash(:error, error)
    |> redirect(to: path)
    |> halt()
  end

  defp context_type(%{"as" => "oauth"}), do: :oauth
  defp context_type(%{"as" => "client"}), do: :gui_client
  defp context_type(%{"as" => "gui-client"}), do: :gui_client
  defp context_type(%{"as" => "headless-client"}), do: :headless_client
  defp context_type(_), do: :portal

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Userpass

    def get_provider(account, id) do
      from(p in Userpass.AuthProvider,
        where: p.account_id == ^account.id and p.id == ^id and not p.is_disabled
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_actor_by_email(account, email) do
      from(a in Portal.Actor,
        where: a.email == ^email and a.account_id == ^account.id and a.is_disabled == false
      )
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
