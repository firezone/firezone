defmodule Domain.Auth.Roles do
  alias Domain.Auth.Role

  def list_roles do
    [
      build(:admin),
      build(:unprivileged)
    ]
  end

  defp list_authorizers do
    [
      Domain.Config.Authorizer,
      Domain.ApiTokens.Authorizer,
      Domain.ConnectivityChecks.Authorizer,
      Domain.Devices.Authorizer,
      Domain.Clients.Authorizer,
      Domain.Gateways.Authorizer,
      Domain.Relays.Authorizer,
      Domain.Rules.Authorizer,
      Domain.Users.Authorizer
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
