defmodule Domain.Telemetry.Reporter.Oban do
  @moduledoc """
  A simple module for reporting Oban job exceptions to Sentry.

  This reporter handles all Oban job failures and sends them to Sentry with
  contextual information. For wrapper exceptions like Domain.Entra.SyncError
  and Domain.Google.SyncError, the original exception/error is extracted and
  reported with additional attributes from the wrapper.

  Additionally, this module handles sync errors intelligently by:
  - Disabling directories on 4xx API errors
  - Extracting meaningful error messages from API responses
  - Storing error information for debugging
  """

  def attach do
    :telemetry.attach("oban-errors", [:oban, :job, :exception], &__MODULE__.handle_event/4, [])
  end

  def handle_event([:oban, :job, :exception], _measure, meta, _) do
    extra = build_extra(meta.reason, meta.job)

    dbg(extra)
    dbg(meta)

    # Handle sync errors before reporting to Sentry
    handle_sync_error(meta.reason, extra)

    # Always report the exception itself, not the extracted reason string
    Sentry.capture_exception(meta.reason, stacktrace: meta.stacktrace, extra: extra)
  end

  # Build extra context for Domain.Entra.SyncError
  defp build_extra(
         %Domain.Entra.SyncError{
           reason: reason,
           cause: cause,
           directory_id: directory_id,
           step: step
         },
         job
       ) do
    job
    |> Map.take([:id, :args, :meta, :queue, :worker])
    |> Map.put(:directory_id, directory_id)
    |> Map.put(:step, step)
    |> Map.put(:reason, reason)
    |> Map.put(:cause, cause)
  end

  # Build extra context for Domain.Google.SyncError
  defp build_extra(
         %Domain.Google.SyncError{
           reason: reason,
           cause: cause,
           directory_id: directory_id,
           step: step
         },
         job
       ) do
    job
    |> Map.take([:id, :args, :meta, :queue, :worker])
    |> Map.put(:directory_id, directory_id)
    |> Map.put(:step, step)
    |> Map.put(:reason, reason)
    |> Map.put(:cause, cause)
  end

  # For other exceptions, return basic context
  defp build_extra(_reason, job) do
    job
    |> Map.take([:id, :args, :meta, :queue, :worker])
  end

  # Handle Entra sync errors - disable directory on 4xx errors
  defp handle_sync_error(
         %Domain.Entra.SyncError{},
         %{cause: %Req.Response{status: status} = response, directory_id: directory_id}
       )
       when status >= 400 and status < 500 do
    error_message = extract_entra_error_message(response)
    disable_entra_directory(directory_id, error_message)
  end

  # Handle Google sync errors - disable directory on 4xx errors
  defp handle_sync_error(
         %Domain.Google.SyncError{},
         %{cause: %Req.Response{status: status} = response, directory_id: directory_id}
       )
       when status >= 400 and status < 500 do
    error_message = extract_google_error_message(response)
    disable_google_directory(directory_id, error_message)
  end

  # No special handling for other errors
  defp handle_sync_error(_error, _extra), do: :ok

  # Extract error message from Entra API response
  # Microsoft Graph API format: { "error": { "code": "...", "message": "...", "innerError": {...} } }
  defp extract_entra_error_message(%Req.Response{
         status: status,
         body: %{"error" => error_obj}
       }) do
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

  defp extract_entra_error_message(%Req.Response{status: status}) do
    "Entra API returned HTTP #{status}"
  end

  # Extract error message from Google API response
  # Google API format: { "error": { "code": 403, "message": "...", "errors": [{...}] } }
  defp extract_google_error_message(%Req.Response{
         status: status,
         body: %{"error" => error_obj}
       })
       when is_map(error_obj) do
    code = Map.get(error_obj, "code")
    message = Map.get(error_obj, "message")

    # Extract first error reason if available
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

  # Handle Google OAuth token errors where body is just a string
  defp extract_google_error_message(%Req.Response{status: status, body: body})
       when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  defp extract_google_error_message(%Req.Response{status: status}) do
    "Google API returned HTTP #{status}"
  end

  # Disable Entra directory and store error
  defp disable_entra_directory(directory_id, error_message) do
    import Ecto.Query
    alias Domain.{Entra, Safe}

    from(d in Entra.Directory, where: d.id == ^directory_id)
    |> Safe.unscoped()
    |> Safe.update_all(
      set: [is_disabled: true, disabled_reason: "Sync error", error: error_message]
    )
  end

  # Disable Google directory and store error
  defp disable_google_directory(directory_id, error_message) do
    import Ecto.Query
    alias Domain.{Google, Safe}

    from(d in Google.Directory, where: d.id == ^directory_id)
    |> Safe.unscoped()
    |> Safe.update_all(
      set: [is_disabled: true, disabled_reason: "Sync error", error: error_message]
    )
  end
end
