defmodule FzHttp.Auth do
  use Supervisor
  alias FzHttp.Repo
  alias FzHttp.Config
  alias FzHttp.{Users, ApiTokens}
  alias FzHttp.Auth.{Subject, Context, Permission, Roles}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      FzHttp.Auth.SAML.StartProxy,
      {DynamicSupervisor, name: FzHttp.RefresherSupervisor, strategy: :one_for_one},
      FzHttp.Auth.OIDC.RefreshManager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def has_permission?(
        %Subject{permissions: granted_permissions},
        %Permission{} = required_permission
      ) do
    Enum.member?(granted_permissions, required_permission)
  end

  def has_permission?(
        %Subject{} = subject,
        {:one_of, required_permissions}
      ) do
    Enum.any?(required_permissions, fn required_permission ->
      has_permission?(subject, required_permission)
    end)
  end

  def has_permissions?(%Subject{} = subject, required_permissions) do
    ensure_has_permissions(subject, required_permissions) == :ok
  end

  def ensure_has_permissions(%Subject{} = subject, required_permissions) do
    required_permissions
    |> List.wrap()
    |> Enum.reject(fn required_permission ->
      has_permission?(subject, required_permission)
    end)
    |> Enum.uniq()
    |> case do
      [] -> :ok
      missing_permissions -> {:error, {:unauthorized, missing_permissions: missing_permissions}}
    end
  end

  def fetch_user_role!(%Users.User{} = user) do
    Roles.build(user.role)
  end

  def fetch_subject!(%Users.User{} = user, remote_ip, user_agent) do
    role = fetch_user_role!(user)

    %Subject{
      actor: {:user, user},
      permissions: role.permissions,
      context: %Context{remote_ip: remote_ip, user_agent: user_agent}
    }
  end

  def fetch_subject!(%ApiTokens.ApiToken{} = api_token, remote_ip, user_agent) do
    api_token = Repo.preload(api_token, :user)
    role = fetch_user_role!(api_token.user)

    # XXX: Once we build audit logging here we need to build a different kind of subject
    %Subject{
      actor: {:user, api_token.user},
      permissions: role.permissions,
      context: %Context{remote_ip: remote_ip, user_agent: user_agent}
    }
  end

  def fetch_oidc_provider_config(provider_id) do
    with {:ok, provider} <- fetch_provider(:openid_connect_providers, provider_id) do
      redirect_uri =
        if provider.redirect_uri do
          provider.redirect_uri
        else
          external_url = FzHttp.Config.fetch_env!(:fz_http, :external_url)
          "#{external_url}auth/oidc/#{provider.id}/callback/"
        end

      {:ok,
       %{
         discovery_document_uri: provider.discovery_document_uri,
         client_id: provider.client_id,
         client_secret: provider.client_secret,
         redirect_uri: redirect_uri,
         response_type: provider.response_type,
         scope: provider.scope
       }}
    end
  end

  def auto_create_users?(field, provider_id) do
    fetch_provider!(field, provider_id).auto_create_users
  end

  defp fetch_provider(field, provider_id) do
    Config.fetch_config!(field)
    |> Enum.find(&(&1.id == provider_id))
    |> case do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  defp fetch_provider!(field, provider_id) do
    case fetch_provider(field, provider_id) do
      {:ok, provider} ->
        provider

      {:error, :not_found} ->
        raise RuntimeError, "Unknown provider #{provider_id}"
    end
  end
end
