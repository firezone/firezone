defmodule PortalAPI.MCP.Safety do
  @moduledoc """
  Informational warnings for tools that change identities/trust or issue credentials.

  OAuth scopes and actor permissions control access to these tools.
  """

  def warning(method, path) do
    case category(method, path) do
      :identity_management ->
        "Security-sensitive: can change administrator access, sign-in settings, or device trust."

      :credential_issuance ->
        "Security-sensitive: returns a live credential to the MCP client. Store it securely. " <>
          "Disconnecting OAuth does not revoke credentials issued by this tool."

      nil ->
        nil
    end
  end

  defp category(:post, "/actors"), do: :identity_management
  defp category(method, "/actors/{id}") when method in [:put, :patch], do: :identity_management
  defp category(:put, "/clients/{id}/verify"), do: :identity_management
  defp category(:post, "/actors/{actor_id}/client_tokens"), do: :credential_issuance
  defp category(:post, "/sites/{site_id}/gateways/{gateway_id}/token"), do: :credential_issuance
  defp category(:post, "/sites/{site_id}/gateways/{gateway_id}/token/rotate"), do: :credential_issuance
  defp category(_method, _path), do: nil
end
