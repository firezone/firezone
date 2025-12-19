defmodule Domain.Telemetry.Reporter.Oban do
  alias __MODULE__.DB

  @moduledoc """
  A simple module for reporting Oban job exceptions to Sentry.

  This reporter handles all Oban job failures and sends them to Sentry with
  contextual information. For wrapper exceptions like Domain.Entra.SyncError,
  Domain.Google.SyncError,and Domain.Okta.SyncError the original exception/error
  is extracted and reported with additional attributes from the wrapper.

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

  defp build_extra(
         %Domain.Okta.SyncError{
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

  # Handle Entra sync errors with 4xx/5xx logic
  defp handle_sync_error(
         %Domain.Entra.SyncError{},
         %{cause: %Req.Response{status: status} = response, directory_id: directory_id}
       )
       when status >= 400 and status < 500 do
    error_message = extract_entra_error_message(response)
    handle_4xx_error(:entra, directory_id, error_message)
  end

  defp handle_sync_error(
         %Domain.Entra.SyncError{},
         %{cause: %Req.Response{status: status} = response, directory_id: directory_id}
       )
       when status >= 500 do
    error_message = extract_entra_error_message(response)
    handle_5xx_error(:entra, directory_id, error_message)
  end

  # Handle Google sync errors with 4xx/5xx logic
  defp handle_sync_error(
         %Domain.Google.SyncError{},
         %{cause: %Req.Response{status: status} = response, directory_id: directory_id}
       )
       when status >= 400 and status < 500 do
    error_message = extract_google_error_message(response)
    handle_4xx_error(:google, directory_id, error_message)
  end

  defp handle_sync_error(
         %Domain.Google.SyncError{},
         %{cause: %Req.Response{status: status} = response, directory_id: directory_id}
       )
       when status >= 500 do
    error_message = extract_google_error_message(response)
    handle_5xx_error(:google, directory_id, error_message)
  end

  # Handle Okta sync errors with 4xx/5xx logic
  defp handle_sync_error(
         %Domain.Okta.SyncError{},
         %{cause: %Req.Response{status: status} = response, directory_id: directory_id}
       )
       when status >= 400 and status < 500 do
    error_message = extract_okta_error_message(response)
    handle_4xx_error(:okta, directory_id, error_message)
  end

  defp handle_sync_error(
         %Domain.Okta.SyncError{},
         %{cause: %Req.Response{status: status} = response, directory_id: directory_id}
       )
       when status >= 500 do
    error_message = extract_okta_error_message(response)
    handle_5xx_error(:okta, directory_id, error_message)
  end

  # Handle any other sync errors (non-HTTP errors)
  defp handle_sync_error(
         %Domain.Entra.SyncError{reason: reason},
         %{directory_id: directory_id}
       ) do
    handle_5xx_error(:entra, directory_id, to_string(reason))
  end

  defp handle_sync_error(
         %Domain.Google.SyncError{reason: reason},
         %{directory_id: directory_id}
       ) do
    handle_5xx_error(:google, directory_id, to_string(reason))
  end

  defp handle_sync_error(
         %Domain.Okta.SyncError{reason: reason},
         %{directory_id: directory_id}
       ) do
    handle_5xx_error(:okta, directory_id, to_string(reason))
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

  # Extract error message from Okta API response
  # Okta API format: { "errorCode": "...", "errorSummary": "...", "errorLink": "...", "errorId": "..." }
  defp extract_okta_error_message(%Req.Response{
         status: status,
         body: %{"errorCode" => error_code, "errorSummary" => error_summary}
       }) do
    parts =
      [
        "HTTP #{status}",
        if(error_code, do: "Code: #{error_code}"),
        if(error_summary, do: error_summary)
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, " - ")
  end

  # Handle Okta OAuth token errors where body might be different
  defp extract_okta_error_message(%Req.Response{status: status, body: body})
       when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  defp extract_okta_error_message(%Req.Response{status: status}) do
    "Okta API returned HTTP #{status}"
  end

  # Handle 4xx errors - disable directory immediately
  defp handle_4xx_error(provider, directory_id, error_message) do
    now = DateTime.utc_now()

    case DB.get_directory(provider, directory_id) do
      # Directory doesn't exist, nothing to update
      nil ->
        :ok

      directory ->
        DB.update_directory(directory, %{
          "errored_at" => now,
          "error_message" => error_message,
          "is_disabled" => true,
          "disabled_reason" => "Sync error",
          "is_verified" => false
        })
    end
  end

  # Handle 5xx errors - disable after 24 hours
  # This allows for transient server issues to resolve before disabling
  # a sync and alerting the admin about it.
  defp handle_5xx_error(provider, directory_id, error_message) do
    now = DateTime.utc_now()

    case DB.get_directory(provider, directory_id) do
      # Directory doesn't exist, nothing to update
      nil ->
        :ok

      directory ->
        # If errored_at is not set, set it now
        errored_at = directory.errored_at || now

        # Check if we're past the 24-hour grace period
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

        DB.update_directory(directory, updates)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, Entra, Google, Okta}

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
