defmodule Web.UserpassController do
  @moduledoc """
  Controller for handling user/password authentication.
  """
  use Web, :controller

  alias Domain.Userpass

  alias __MODULE__.DB
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
    email = userpass["idp_id"]
    password = userpass["secret"]
    context_type = context_type(params)

    with %Domain.Account{} = account <- DB.get_account_by_id_or_slug(account_id_or_slug),
         %Userpass.AuthProvider{} = provider <- fetch_provider(account, auth_provider_id),
         %Domain.Actor{} = actor <- fetch_actor(account, email),
         :ok <- check_admin(actor, context_type),
         {:ok, actor, _expires_at} <- verify_password(actor, password, conn),
         {:ok, token} <- create_token(conn, actor, provider, params) do
      signed_in(conn, context_type, account, actor, token, params)
    else
      error -> handle_error(conn, error, params)
    end
  end

  def sign_in(conn, params) do
    Logger.warning("Invalid request parameters", params: params)
    handle_error(conn, :invalid_params, params)
  end

  defp verify_password(actor, password, _conn) do
    password_hash = actor.password_hash

    cond do
      is_nil(password_hash) ->
        {:error, :invalid_secret}

      not Domain.Crypto.equal?(:argon2, password, password_hash) ->
        {:error, :invalid_secret}

      true ->
        {:ok, actor, nil}
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

    with {:ok, token} <- Domain.Auth.create_token(attrs) do
      {:ok, Domain.Auth.encode_fragment!(token)}
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

  defp fetch_provider(account, id) do
    DB.get_provider(account, id)
  end

  defp fetch_actor(account, email) do
    DB.get_actor_by_email(account, email)
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

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Account
    alias Domain.Userpass

    def get_account_by_id_or_slug(id_or_slug) do
      query =
        if match?({:ok, _}, Ecto.UUID.cast(id_or_slug)),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped() |> Safe.one()
    end

    def get_provider(account, id) do
      from(p in Userpass.AuthProvider,
        where: p.account_id == ^account.id and p.id == ^id and not p.is_disabled
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_actor_by_email(account, email) do
      from(a in Domain.Actor,
        where: a.email == ^email and a.account_id == ^account.id and is_nil(a.disabled_at)
      )
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
