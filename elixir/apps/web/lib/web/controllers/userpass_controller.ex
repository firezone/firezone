defmodule Web.UserpassController do
  @moduledoc """
  Controller for handling user/password authentication.
  """
  use Web, :controller

  alias Domain.{
    Accounts,
    Auth,
    Repo,
    Tokens,
    Userpass
  }

  alias Web.Session.Redirector

  require Logger

  action_fallback Web.FallbackController

  def sign_in(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "auth_provider_id" => auth_provider_id,
          "userpass" => userpass
        } = params
      ) do
    issuer = "firezone"
    idp_id = userpass["idp_id"]
    password = userpass["secret"]
    context_type = context_type(params)

    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
         %Userpass.AuthProvider{} = provider <- fetch_provider(account, auth_provider_id),
         %Auth.Identity{} = identity <- fetch_identity(account, issuer, idp_id),
         :ok <- check_admin(identity, context_type),
         {:ok, identity, _expires_at} <- verify_password(identity, password, conn),
         {:ok, token} <- create_token(conn, identity, provider, params) do
      signed_in(conn, context_type, account, identity, token, params)
    else
      error -> handle_error(conn, error, params)
    end
  end

  def sign_in(conn, params) do
    Logger.warning("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  defp verify_password(identity, password, _conn) do
    # Inlined from Domain.Auth.Adapters.UserPass.verify_secret
    password_hash = identity.password_hash

    cond do
      is_nil(password_hash) ->
        {:error, :invalid_secret}

      not Domain.Crypto.equal?(:argon2, password, password_hash) ->
        {:error, :invalid_secret}

      true ->
        {:ok, identity, nil}
    end
  end

  defp check_admin(
         %Auth.Identity{actor: %Domain.Actors.Actor{type: :account_admin_user}},
         _context_type
       ),
       do: :ok

  defp check_admin(%Auth.Identity{actor: %Domain.Actors.Actor{type: :account_user}}, :client),
    do: :ok

  defp check_admin(_identity, _context_type), do: {:error, :not_admin}

  defp create_token(conn, identity, provider, params) do
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
      account_id: identity.account_id,
      actor_id: identity.actor_id,
      auth_provider_id: params["auth_provider_id"],
      identity_id: identity.id,
      expires_at: DateTime.add(DateTime.utc_now(), session_lifetime_secs, :second),
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

  defp fetch_provider(account, id) do
    import Ecto.Query

    # Fetch the email OTP auth provider by account and id, ensuring it is not disabled
    from(p in Userpass.AuthProvider,
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
    |> preload([i, a], actor: a)
    |> Repo.one()
  end

  defp handle_error(conn, {:error, :not_found}, params) do
    error = "You may not use this method to sign in."
    path = ~p"/#{params["account_id_or_slug"]}"
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, :invalid_secret}, _params) do
    error = "Invalid username or password."
    path = conn.request_path
    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, :not_admin}, params) do
    error = "This action requires admin privileges."
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

  defp context_type(%{"as" => "client"}), do: :client
  defp context_type(_), do: :browser
end
