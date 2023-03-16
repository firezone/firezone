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
          all_permissions_from(FzHttp.ConnectivityChecks.Authorizer),
          all_permissions_from(FzHttp.Devices.Authorizer)
        ])
    }
  end

  def role(:unprivileged) do
    %Role{
      name: :unprivileged,
      permissions:
        permissions(
          [
            FzHttp.ApiTokens.Authorizer.view_api_tokens_permission(),
            FzHttp.ApiTokens.Authorizer.manage_owned_api_tokens_permission(),
            FzHttp.Devices.Authorizer.view_devices_permission()
          ] ++
            if FzHttp.Config.fetch_config!(:allow_unprivileged_device_management) do
              [
                FzHttp.Devices.Authorizer.create_own_devices_permission(),
                FzHttp.Devices.Authorizer.update_owned_devices_permission(),
                FzHttp.Devices.Authorizer.delete_owned_devices_permission()
              ]
            else
              []
            end
        )
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
