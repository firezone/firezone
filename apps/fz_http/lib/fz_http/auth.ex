defmodule FzHttp.Auth do
  alias FzHttp.Config
  alias FzHttp.Users
  alias FzHttp.Auth.{Subject, Context, Permission, Roles}

  def has_permission?(
        %Subject{permissions: granted_permissions},
        %Permission{} = required_permission
      ) do
    Enum.member?(granted_permissions, required_permission)
  end

  def ensure_has_permissions(%Subject{} = subject, required_permissions) do
    required_permissions
    |> List.wrap()
    |> Enum.reject(fn %Permission{} = requested_permission ->
      has_permission?(subject, requested_permission)
    end)
    |> Enum.uniq()
    |> case do
      [] -> :ok
      missing_permissions -> {:error, {:unauthorized, missing_permissions: missing_permissions}}
    end
  end

  # TODO: clean unused funs after refactoring
  def actor_is?(%Subject{} = subject, actor_type) do
    Subject.actor_type(subject) == actor_type
  end

  def ensure_actor(%Subject{} = subject, actor_type) do
    if actor_is?(subject, actor_type) do
      :ok
    else
      {:error, {:unauthorized, actor_is_not_a: actor_type}}
    end
  end

  def fetch_user_role!(%Users.User{} = user) do
    Roles.role(user.role)
  end

  def fetch_subject!(%Users.User{} = user, remote_ip, user_agent) do
    role = fetch_user_role!(user)

    %Subject{
      actor: {:user, user},
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
