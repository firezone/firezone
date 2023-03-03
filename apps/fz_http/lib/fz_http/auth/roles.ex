defmodule FzHttp.Auth.Roles do
  alias FzHttp.Auth.Role

  def list_roles do
    [
      role(:admin),
      role(:unprivileged)
    ]
  end

  def role(:admin) do
    %Role{
      name: :admin,
      permissions:
        permissions([
          all_permissions_from(FzHttp.ApiTokens.Authorizer),
          all_permissions_from(FzHttp.ConnectivityChecks.Authorizer)
        ])
    }
  end

  def role(:unprivileged) do
    %Role{
      name: :unprivileged,
      permissions:
        permissions([
          FzHttp.ApiTokens.Authorizer.view_api_tokens_permission(),
          FzHttp.ApiTokens.Authorizer.manage_owned_api_tokens_permission()
        ])
    }
  end

  defp permissions(permissions) do
    permissions
    |> List.flatten()
    |> MapSet.new()
  end

  defp all_permissions_from(authorizer) do
    authorizer.list_permissions()
  end
end
