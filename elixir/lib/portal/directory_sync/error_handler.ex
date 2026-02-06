defmodule Portal.DirectorySync.ErrorHandler do
  @moduledoc """
  Handles errors from directory sync Oban jobs (Entra, Google, Okta).

  Routes errors to provider-specific handlers and builds Sentry context.
  """

  @doc """
  Handle an error from a directory sync job.

  Routes to the appropriate provider handler and returns Sentry context.
  """
  def handle_error(%{reason: reason, job: job}) do
    directory_id = job.args["directory_id"]

    case job.worker do
      "Portal.Entra.Sync" -> Portal.Entra.ErrorHandler.handle(reason, directory_id)
      "Portal.Google.Sync" -> Portal.Google.ErrorHandler.handle(reason, directory_id)
      "Portal.Okta.Sync" -> Portal.Okta.ErrorHandler.handle(reason, directory_id)
      _ -> :ok
    end

    build_sentry_context(reason, job)
  end

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

  # Sentry context building

  defp build_sentry_context(
         %{
           __struct__: struct,
           error: error,
           directory_id: directory_id,
           step: step
         },
         job
       )
       when struct in [Portal.Entra.SyncError, Portal.Google.SyncError, Portal.Okta.SyncError] do
    job
    |> Map.take([:id, :args, :meta, :queue, :worker])
    |> Map.put(:directory_id, directory_id)
    |> Map.put(:step, step)
    |> Map.put(:error, inspect(error))
  end

  defp build_sentry_context(_reason, job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
  end
end
