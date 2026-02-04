defmodule Portal.DirectorySync.ErrorFormatter do
  @moduledoc """
  Behavior for provider-specific directory sync error formatting.

  Each provider (Entra, Google, Okta) implements this behavior to:
  - Classify errors as `:client_error` (disable immediately) or `:transient` (retry)
  - Format error contexts into user-friendly messages
  """

  @type error_type :: :client_error | :transient
  @type classification :: {error_type(), String.t()}

  @doc """
  Classify and format an error context.

  Returns a tuple of `{error_type, message}` where:
  - `:client_error` - User action required, disable directory immediately
  - `:transient` - Temporary error, will retry and disable after 24 hours
  """
  @callback classify_and_format(context :: term()) :: classification()

  @doc """
  Format a generic error (non-SyncError exceptions).

  Used when the error doesn't match the provider's SyncError struct.
  """
  @callback format_generic_error(error :: term()) :: String.t()

  @doc """
  Format network/transport errors into user-friendly messages.

  Handles DNS failures, timeouts, TLS errors, and other network issues.
  This is shared across all providers.
  """
  @spec format_transport_error(Exception.t()) :: String.t()
  def format_transport_error(%Req.TransportError{reason: reason}) do
    case reason do
      :nxdomain ->
        "DNS lookup failed."

      :timeout ->
        "Connection timed out."

      :connect_timeout ->
        "Connection timed out."

      :econnrefused ->
        "Connection refused."

      :closed ->
        "Connection closed unexpectedly."

      {:tls_alert, {alert_type, _}} ->
        "TLS error (#{alert_type})."

      :ehostunreach ->
        "Host is unreachable."

      :enetunreach ->
        "Network is unreachable."

      _ ->
        "Network error: #{inspect(reason)}"
    end
  end
end
