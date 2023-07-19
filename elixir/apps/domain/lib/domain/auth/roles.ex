defmodule Domain.Auth.Roles do
  alias Domain.Auth.Role

  def list_roles do
    [
      build(:account_admin_user),
      build(:account_user)
    ]
  end

  defp list_authorizers do
    [
      Domain.Auth.Authorizer,
      Domain.Config.Authorizer,
      Domain.Accounts.Authorizer,
      Domain.Devices.Authorizer,
      Domain.Gateways.Authorizer,
      Domain.Relays.Authorizer,
      Domain.Actors.Authorizer,
      Domain.Resources.Authorizer
    ]
  end

  def build(role) do
    %Role{
      name: role,
      permissions:
        list_authorizers()
        |> Enum.map(&fetch_permissions_for_role(&1, role))
        |> permissions()
    }
  end

  defp permissions(permissions) do
    permissions
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp fetch_permissions_for_role(authorizer, role) do
    authorizer.list_permissions_for_role(role)
  end
end
