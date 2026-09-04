defmodule PortalAPI.MCP.Safety do
  @moduledoc """
  Operator opt-ins for tools that change identities/trust or issue credentials.

  These gates supplement OAuth scopes and actor permissions. Annotation hints
  are informational and never grant permission to execute a tool.
  """

  alias PortalAPI.MCP.Tool

  def enabled?(%Tool{method: method, path_template: path}) do
    case feature(method, path) do
      nil -> true
      feature -> Portal.Features.enabled?(feature)
    end
  end

  def permit(tool) do
    if enabled?(tool), do: :ok, else: {:error, "This security-sensitive tool is disabled by the operator."}
  end

  def warning(method, path) do
    case feature(method, path) do
      :mcp_identity_management ->
        "Security-sensitive: can change administrator access, sign-in settings, or device trust. " <>
          "Requires the operator's mcp_identity_management opt-in."

      :mcp_credential_issuance ->
        "Security-sensitive: returns a live credential to the MCP client. Store it securely. " <>
          "Disconnecting OAuth does not revoke credentials issued by this tool. " <>
          "Requires the operator's mcp_credential_issuance opt-in."

      nil ->
        nil
    end
  end

  defp feature(:post, "/actors"), do: :mcp_identity_management
  defp feature(method, "/actors/{id}") when method in [:put, :patch], do: :mcp_identity_management
  defp feature(:put, "/clients/{id}/verify"), do: :mcp_identity_management
  defp feature(:post, "/actors/{actor_id}/client_tokens"), do: :mcp_credential_issuance
  defp feature(:post, "/sites/{site_id}/gateways/{gateway_id}/token"), do: :mcp_credential_issuance
  defp feature(:post, "/sites/{site_id}/gateways/{gateway_id}/token/rotate"), do: :mcp_credential_issuance
  defp feature(_method, _path), do: nil
end
