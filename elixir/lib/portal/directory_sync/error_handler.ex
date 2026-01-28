defmodule Portal.DirectorySync.ErrorHandler do
  @moduledoc """
  Handles errors from directory sync Oban jobs (Entra, Google, Okta).

  This module is responsible for:
  - Extracting meaningful error messages from exceptions
  - Updating directory state based on error type
  - Disabling directories on persistent errors

  Error handling strategy:
  - 4xx HTTP errors: Disable directory immediately (user action required)
  - 5xx HTTP errors: Record error, disable after 24 hours (transient)
  - Network/transport errors: Treat as transient (5xx behavior)
  - Other errors: Treat as transient (5xx behavior)
  """

  alias __MODULE__.Database
  require Logger

  @doc """
  Handle an error from a directory sync job.

  Extracts the directory_id from job args, delegates to provider-specific handling,
  and returns extra context for Sentry reporting.
  """
  def handle_error(%{reason: reason, job: job}) do
    directory_id = job.args["directory_id"]

    case job.worker do
      "Portal.Entra.Sync" -> handle_entra_error(reason, directory_id)
      "Portal.Google.Sync" -> handle_google_error(reason, directory_id)
      "Portal.Okta.Sync" -> handle_okta_error(reason, directory_id)
      _ -> :ok
    end

    build_sentry_context(reason, job)
  end

  # Entra error handling

  defp handle_entra_error(%Portal.Entra.SyncError{cause: cause}, directory_id) do
    {error_type, message} = classify_error(cause, &format_entra_error/1)
    update_directory(:entra, directory_id, error_type, message)
  end

  defp handle_entra_error(error, directory_id) do
    message = format_generic_error(error)
    update_directory(:entra, directory_id, :transient, message)
  end

  # Google error handling

  defp handle_google_error(%Portal.Google.SyncError{cause: cause}, directory_id) do
    {error_type, message} = classify_error(cause, &format_google_error/1)
    update_directory(:google, directory_id, error_type, message)
  end

  defp handle_google_error(error, directory_id) do
    message = format_generic_error(error)
    update_directory(:google, directory_id, :transient, message)
  end

  # Okta error handling

  defp handle_okta_error(%Portal.Okta.SyncError{cause: cause}, directory_id) do
    {error_type, message} = classify_error(cause, &format_okta_error/1)
    update_directory(:okta, directory_id, error_type, message)
  end

  defp handle_okta_error(error, directory_id) do
    message = format_generic_error(error)
    update_directory(:okta, directory_id, :transient, message)
  end

  # Error classification

  defp classify_error(%Req.Response{status: status} = response, format_fn)
       when status >= 400 and status < 500 do
    {:client_error, format_fn.(response)}
  end

  defp classify_error(%Req.Response{status: status} = response, format_fn)
       when status >= 500 do
    {:transient, format_fn.(response)}
  end

  defp classify_error(%Req.Response{} = response, format_fn) do
    {:transient, format_fn.(response)}
  end

  defp classify_error(%Req.TransportError{} = error, _format_fn) do
    {:transient, format_transport_error(error)}
  end

  defp classify_error(%{step: :check_deletion_threshold} = cause, _format_fn) do
    {:client_error, format_deletion_threshold_error(cause)}
  end

  defp classify_error(%{step: :process_user} = cause, _format_fn) do
    {:client_error, Map.get(cause, :reason, "User missing required email field")}
  end

  defp classify_error(%{step: :verify_scopes} = cause, _format_fn) do
    {:client_error, Map.get(cause, :reason, "Access token missing required scopes")}
  end

  defp classify_error(error, _format_fn) do
    {:transient, format_generic_error(error)}
  end

  # Error formatting

  defp format_entra_error(%Req.Response{status: status, body: %{"error" => error_obj}}) do
    code = Map.get(error_obj, "code")
    message = Map.get(error_obj, "message")
    inner_code = get_in(error_obj, ["innerError", "code"])

    parts =
      [
        "HTTP #{status}",
        if(code, do: "Code: #{code}"),
        if(inner_code && inner_code != code, do: "Inner Code: #{inner_code}"),
        if(message, do: message)
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, " - ")
  end

  defp format_entra_error(%Req.Response{status: status, body: body}) when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  defp format_entra_error(%Req.Response{status: status}) do
    "Entra API returned HTTP #{status}"
  end

  defp format_google_error(%Req.Response{status: status, body: %{"error" => error_obj}})
       when is_map(error_obj) do
    code = Map.get(error_obj, "code")
    message = Map.get(error_obj, "message")

    reason =
      case Map.get(error_obj, "errors") do
        [%{"reason" => r} | _] -> r
        _ -> nil
      end

    parts =
      [
        "HTTP #{status}",
        if(code && code != status, do: "Code: #{code}"),
        if(reason, do: "Reason: #{reason}"),
        if(message, do: message)
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, " - ")
  end

  defp format_google_error(%Req.Response{status: status, body: body}) when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  defp format_google_error(%Req.Response{status: status}) do
    "Google API returned HTTP #{status}"
  end

  defp format_okta_error(%Req.Response{status: status, body: body}) when is_map(body) do
    Portal.Okta.ErrorCodes.format_error(status, body)
  end

  defp format_okta_error(%Req.Response{status: status, body: body}) when is_binary(body) do
    Portal.Okta.ErrorCodes.format_error(status, body)
  end

  defp format_okta_error(%Req.Response{status: status}) do
    Portal.Okta.ErrorCodes.format_error(status, nil)
  end

  @doc """
  Format network/transport errors into user-friendly messages.

  Handles DNS failures, timeouts, TLS errors, and other network issues.
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

  defp format_deletion_threshold_error(%{resource: resource, total: total, to_delete: to_delete}) do
    percentage = if total > 0, do: Float.round(to_delete / total * 100, 0), else: 0

    "Sync would delete #{to_delete} of #{total} #{resource} (#{trunc(percentage)}%). " <>
      "This may indicate your Okta application was misconfigured. " <>
      "Please verify your Okta configuration and re-verify the directory."
  end

  defp format_deletion_threshold_error(_cause) do
    "Deletion threshold exceeded. Please verify your Okta configuration."
  end

  defp format_generic_error(error) when is_exception(error) do
    Exception.message(error)
  end

  defp format_generic_error(error) do
    inspect(error)
  end

  # Directory updates

  defp update_directory(provider, directory_id, error_type, error_message) do
    now = DateTime.utc_now()

    case Database.get_directory(provider, directory_id) do
      nil ->
        Logger.info("Directory not found, skipping error update",
          provider: provider,
          directory_id: directory_id
        )

        :ok

      directory ->
        do_update_directory(directory, error_type, error_message, now)
    end
  end

  defp do_update_directory(directory, :client_error, error_message, now) do
    # 4xx errors - disable immediately, user action required
    Database.update_directory(directory, %{
      "errored_at" => now,
      "error_message" => error_message,
      "is_disabled" => true,
      "disabled_reason" => "Sync error",
      "is_verified" => false
    })
  end

  defp do_update_directory(directory, :transient, error_message, now) do
    # Transient errors - record error, disable after 24 hours
    errored_at = directory.errored_at || now
    hours_since_error = DateTime.diff(now, errored_at, :hour)
    should_disable = hours_since_error >= 24

    updates = %{
      "errored_at" => errored_at,
      "error_message" => error_message
    }

    updates =
      if should_disable do
        Map.merge(updates, %{
          "is_disabled" => true,
          "disabled_reason" => "Sync error",
          "is_verified" => false
        })
      else
        updates
      end

    Database.update_directory(directory, updates)
  end

  # Sentry context building

  defp build_sentry_context(
         %{
           __struct__: struct,
           reason: reason,
           cause: cause,
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
    |> Map.put(:reason, reason)
    |> Map.put(:cause, format_cause(cause))
  end

  defp build_sentry_context(_reason, job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
  end

  defp format_cause(%Req.Response{status: status, body: body}) when is_map(body) do
    %{type: "Req.Response", status: status, body: body}
  end

  defp format_cause(%Req.Response{status: status, body: body}) when is_binary(body) do
    %{type: "Req.Response", status: status, body: String.slice(body, 0, 500)}
  end

  defp format_cause(%Req.Response{status: status}) do
    %{type: "Req.Response", status: status}
  end

  defp format_cause(%Req.TransportError{reason: reason}) do
    %{type: "Req.TransportError", reason: inspect(reason)}
  end

  defp format_cause(cause) when is_exception(cause) do
    %{type: inspect(cause.__struct__), message: Exception.message(cause)}
  end

  defp format_cause(cause) do
    inspect(cause)
  end

  defmodule Database do
    @moduledoc false

    import Ecto.Query
    alias Portal.{Safe, Entra, Google, Okta}

    def get_directory(:entra, directory_id) do
      from(d in Entra.Directory, where: d.id == ^directory_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_directory(:google, directory_id) do
      from(d in Google.Directory, where: d.id == ^directory_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_directory(:okta, directory_id) do
      from(d in Okta.Directory, where: d.id == ^directory_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def update_directory(directory, attrs) do
      changeset =
        Ecto.Changeset.cast(directory, attrs, [
          :errored_at,
          :error_message,
          :is_disabled,
          :disabled_reason,
          :is_verified
        ])

      {:ok, _directory} = changeset |> Safe.unscoped() |> Safe.update()
    end
  end
end
