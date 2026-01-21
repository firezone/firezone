defmodule Portal.Okta.ErrorCodes do
  @moduledoc """
  Maps Okta API error codes to actionable customer messages.
  Single source of truth for both verification and sync error handling.
  """

  # Error code → resolution mapping
  @error_codes %{
    # Authentication (401)
    "E0000004" =>
      "Verify your Okta API credentials. Check that the Client ID is correct and the private key matches the public key configured in Okta.",
    "E0000011" =>
      "Invalid token. Please ensure your Client ID and private key are correct and the JWT is properly signed.",
    "E0000061" => "Access denied. The client application is not authorized to use this API.",
    "E0000015" => "This feature requires a higher Okta plan. Contact your Okta administrator.",

    # Authorization (403)
    "E0000006" =>
      "Access denied. You do not have permission to perform this action. Ensure the API service app has the required scopes: okta.users.read, okta.groups.read, okta.apps.read",
    "E0000022" =>
      "API access denied. The feature may not be available for your Okta organization.",

    # Validation (400)
    "E0000001" => "API validation failed. Check your request parameters.",
    "E0000003" => "The request body was invalid. Please check your configuration.",
    "E0000021" => "Bad request to Okta API. Please verify your Okta domain and API configuration.",

    # Rate Limiting (429)
    "E0000047" => "The Okta API rate limit has been exceeded. Syncs will automatically retry.",

    # Not Found (404)
    "E0000007" => "Resource not found. Please verify your Okta domain is correct.",
    "E0000008" =>
      "The API endpoint was not found. Verify your Okta domain (e.g., your-org.okta.com).",
    "E0000048" =>
      "The requested entity does not exist in Okta. It may have been recently deleted.",

    # Server Errors (500+)
    "E0000009" =>
      "Okta experienced an internal error. Syncs will automatically retry. Check status.okta.com if this persists.",
    "E0000010" =>
      "Okta is in read-only maintenance mode. Syncs will automatically retry once maintenance completes."
  }

  # Special handling for invalid_client which has different messages based on status
  @invalid_client_messages %{
    400 => "Invalid client application. Please verify your Client ID is correct.",
    401 =>
      "Client authentication failed. Please verify your Client ID and ensure the public key is registered in Okta."
  }

  @empty_resource_messages %{
    apps:
      "No apps found in your Okta account. Please ensure the OIDC app is created and that the API service integration app has the okta.apps.read scope granted.",
    users:
      "No users found in your Okta account. Please ensure users are assigned to the OIDC app and the API service integration app has the okta.users.read scope granted.",
    groups:
      "No groups found in your Okta account. Please ensure groups are assigned to the OIDC app and the API service integration app has the okta.groups.read scope granted."
  }

  @doc """
  Format error for display.

  Builds a user-friendly error message from an HTTP status and response body.
  Used by both sync errors (oban.ex) and verification errors (directory_sync.ex).
  """
  @spec format_error(integer(), map() | binary() | nil) :: String.t()
  def format_error(status, body) when is_map(body) and map_size(body) > 0 do
    error_code = body["errorCode"] || body["error"]
    error_summary = body["errorSummary"] || body["error_description"]

    cond do
      # Known error code - use resolution message
      resolution = get_resolution(error_code, status) ->
        resolution

      # Unknown error code but has summary - format with status-specific prefix
      error_summary && is_nil(error_code) ->
        "#{summary_prefix(status)}: #{error_summary}"

      # Has error code and summary but no resolution - include both
      error_code && error_summary ->
        "#{summary_prefix(status)} (#{error_code}): #{error_summary}"

      # Only error summary
      error_summary ->
        "#{summary_prefix(status)}: #{error_summary}"

      # Only error code
      error_code ->
        "#{status_label(status)} (#{error_code}). #{default_resolution(status)}"

      # Empty map - use fallback
      true ->
        fallback_message(status)
    end
  end

  def format_error(status, body) when is_binary(body) and byte_size(body) > 0 do
    "HTTP #{status} - #{body}"
  end

  def format_error(status, _body) do
    fallback_message(status)
  end

  @doc """
  Get resolution message for a specific error code.

  Returns the actionable resolution message for known error codes,
  or nil for unknown codes.
  """
  @spec get_resolution(String.t() | nil, integer()) :: String.t() | nil
  def get_resolution(nil, _status), do: nil

  def get_resolution("invalid_client", status) do
    Map.get(@invalid_client_messages, status) ||
      "Client authentication failed. Please verify your Client ID and ensure the public key is registered in Okta."
  end

  def get_resolution(error_code, _status), do: Map.get(@error_codes, error_code)

  @doc """
  Get resolution for empty resource errors.

  Returns an actionable message explaining why no resources were found
  and how to fix it.
  """
  @spec empty_resource_message(:apps | :users | :groups) :: String.t()
  def empty_resource_message(resource) when resource in [:apps, :users, :groups] do
    Map.fetch!(@empty_resource_messages, resource)
  end

  @doc """
  Format network/transport errors into user-friendly messages.

  Handles DNS failures, timeouts, TLS errors, and other network issues.
  """
  @spec format_transport_error(Req.TransportError.t()) :: String.t()
  def format_transport_error(%Req.TransportError{reason: reason}) do
    case reason do
      :nxdomain ->
        "DNS lookup failed. Please verify the Okta domain is spelled correctly."

      :timeout ->
        "Connection timed out. Please check network connectivity."

      :connect_timeout ->
        "Connection timed out. Please check network connectivity."

      :econnrefused ->
        "Connection refused. Please verify the Okta domain is correct."

      :closed ->
        "Connection closed unexpectedly. Please try again."

      {:tls_alert, {alert_type, _}} ->
        "TLS error (#{alert_type}). Please check network configuration."

      :ehostunreach ->
        "Host is unreachable. Please check network connectivity."

      :enetunreach ->
        "Network is unreachable. Please check network connectivity."

      _ ->
        "Network error: #{inspect(reason)}"
    end
  end

  @doc """
  Default resolution based on HTTP status code.

  Used when no specific error code is available.
  """
  @spec default_resolution(integer()) :: String.t()
  def default_resolution(status) when status >= 500 do
    "Okta service is currently unavailable. Please try again later or check status.okta.com"
  end

  def default_resolution(429) do
    "Rate limit exceeded. Syncs will automatically retry."
  end

  def default_resolution(404) do
    "Please verify your Okta domain (e.g., your-org.okta.com) is correct."
  end

  def default_resolution(403) do
    "Ensure the application has okta.users.read and okta.groups.read scopes granted."
  end

  def default_resolution(401) do
    "Please check your Client ID and ensure the public key matches your private key."
  end

  def default_resolution(400) do
    "Please verify your Okta domain and Client ID."
  end

  def default_resolution(_status) do
    "Please verify your Okta configuration."
  end

  # Private helpers

  defp summary_prefix(400), do: "Configuration error"
  defp summary_prefix(401), do: "Authentication failed"
  defp summary_prefix(403), do: "Permission denied"
  defp summary_prefix(404), do: "Not found"
  defp summary_prefix(429), do: "Rate limited"
  defp summary_prefix(_status), do: "Error"

  defp status_label(400), do: "HTTP 400 Bad Request"
  defp status_label(401), do: "HTTP 401 Unauthorized"
  defp status_label(403), do: "HTTP 403 Forbidden"
  defp status_label(404), do: "HTTP 404 Not Found"
  defp status_label(429), do: "HTTP 429 Too Many Requests"
  defp status_label(status) when status >= 500, do: "HTTP #{status} Server Error"
  defp status_label(status), do: "HTTP #{status}"

  defp fallback_message(status) when status >= 500 do
    "Okta service is currently unavailable (HTTP #{status}). Please try again later."
  end

  defp fallback_message(400) do
    "HTTP 400 Bad Request. Please verify your Okta domain and Client ID."
  end

  defp fallback_message(401) do
    "HTTP 401 Unauthorized. Please check your Client ID and ensure the public key matches your private key."
  end

  defp fallback_message(403) do
    "HTTP 403 Forbidden. Ensure the application has okta.users.read and okta.groups.read scopes granted."
  end

  defp fallback_message(404) do
    "HTTP 404 Not Found. Please verify your Okta domain (e.g., your-domain.okta.com) is correct."
  end

  defp fallback_message(status) do
    "Okta API returned HTTP #{status}. #{default_resolution(status)}"
  end
end
