defmodule Domain.Auth.Roles do
  alias Domain.Auth.Role

  defp list_authorizers do
    [
      Domain.Accounts.Authorizer,
      Domain.Actors.Authorizer,
      Domain.Actors.Group.Authorizer,
      Domain.Auth.Authorizer,
      Domain.Billing.Authorizer,
      Domain.Clients.Authorizer,
      Domain.Directories.Authorizer,
      Domain.Email.Authorizer,
      Domain.Entra.Authorizer,
      Domain.Gateways.Authorizer,
      Domain.Google.Authorizer,
      Domain.Okta.Authorizer,
      Domain.Policies.Authorizer,
      Domain.Relays.Authorizer,
      Domain.Resources.Authorizer,
      Domain.Flows.Authorizer,
      Domain.Tokens.Authorizer,
      Domain.Userpass.Authorizer
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
