defmodule Portal.DirectorySync.CommonError do
  @moduledoc """
  Common error formatting for directory sync.

  Provides fallback formatting for transport errors, database errors,
  and generic exceptions used across all providers.
  """

  @doc """
  Format an error into a user-friendly message.

  Handles common error types:
  - Req.TransportError - Network/transport errors
  - Postgrex.Error - Database errors
  - Exceptions - Via Exception.message/1
  - Other terms - Via inspect/1
  """
  @spec format(term()) :: String.t()
  def format(%Req.TransportError{reason: reason}) do
    case reason do
      :nxdomain -> "DNS lookup failed"
      :timeout -> "Connection timed out"
      :connect_timeout -> "Connection timed out"
      :econnrefused -> "Connection refused"
      :closed -> "Connection closed unexpectedly"
      {:tls_alert, {alert_type, _}} -> "TLS error (#{alert_type})"
      :ehostunreach -> "Host is unreachable"
      :enetunreach -> "Network is unreachable"
      _ -> "Network error: #{inspect(reason)}"
    end
  end

  def format(%Postgrex.Error{} = error) do
    "Database error: #{Exception.message(error)}"
  end

  def format(error) when is_exception(error) do
    Exception.message(error)
  end

  def format(error), do: inspect(error)
end
