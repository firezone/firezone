defmodule Portal.Entra.SyncError do
  @moduledoc """
  Exception and error handling for Entra directory sync.

  This module:
  - Defines the SyncError exception raised during sync
  - Handles errors from Oban telemetry via handle_error/1
  - Classifies errors as client_error (disable) or transient (retry)
  - Formats error messages for users and Sentry
  """

  alias Portal.DirectorySync.CommonError

  import Ecto.Query

  require Logger

  defmodule Database do
    alias Portal.Safe

    def get_directory(directory_id) do
      from(d in Portal.Entra.Directory, where: d.id == ^directory_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def update_directory(changeset) do
      changeset |> Safe.unscoped() |> Safe.update()
    end
  end

  # Exception definition
  defexception [:message, :error, :directory_id, :step]

  @impl true
  def exception(opts) do
    error = Keyword.fetch!(opts, :error)
    directory_id = Keyword.fetch!(opts, :directory_id)
    step = Keyword.fetch!(opts, :step)

    message = build_message(error, directory_id, step)

    %__MODULE__{
      message: message,
      error: error,
      directory_id: directory_id,
      step: step
    }
  end

  defp build_message(%Req.Response{status: status, body: body}, directory_id, step)
       when is_integer(status) do
    "Entra sync failed for directory #{directory_id} at #{step}: HTTP #{status} - #{inspect(body)}"
  end

  defp build_message(%Req.TransportError{} = error, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: #{Exception.message(error)}"
  end

  defp build_message({:validation, msg}, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: #{msg}"
  end

  defp build_message({:consent_revoked, msg}, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: #{msg}"
  end

  defp build_message({:batch_all_failed, status, body}, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: batch HTTP #{status} - #{inspect(body)}"
  end

  defp build_message({:batch_request_failed, status, body}, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: batch request HTTP #{status} - #{inspect(body)}"
  end

  defp build_message({:db_error, error}, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: database error: #{inspect(error)}"
  end

  defp build_message(%{__exception__: true} = exception, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: #{Exception.message(exception)}"
  end

  defp build_message(error, directory_id, step) when is_binary(error) do
    "Entra sync failed for directory #{directory_id} at #{step}: #{error}"
  end

  defp build_message(error, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: #{inspect(error)}"
  end

  # Public API for Oban telemetry reporter

  @doc """
  Handle an error from an Entra sync job.

  Called by the Oban telemetry reporter. Classifies the error,
  formats it for display, updates the directory state, and returns
  Sentry context.
  """
  @spec handle_error(map()) :: map()
  def handle_error(%{reason: reason, job: job}) do
    directory_id = job.args["directory_id"]

    case reason do
      %__MODULE__{error: error} = sync_error ->
        {error_type, message} = classify_and_format(error)
        update_directory(directory_id, error_type, message)
        build_sentry_context(sync_error, job)

      error ->
        message = format_generic_error(error)
        update_directory(directory_id, :transient, message)
        build_default_sentry_context(job)
    end
  end

  # Internal classification and formatting

  defp classify_and_format(error) do
    error_type = classify(error)
    message = format(error)
    {error_type, message}
  end

  # HTTP 4xx -> client_error
  defp classify(%Req.Response{status: status}) when status >= 400 and status < 500,
    do: :client_error

  # HTTP 5xx -> transient
  defp classify(%Req.Response{}), do: :transient

  # Network errors -> transient
  defp classify(%Req.TransportError{}), do: :transient

  # Batch errors - classify by status
  defp classify({:batch_all_failed, status, _body}) when status >= 400 and status < 500,
    do: :client_error

  defp classify({:batch_all_failed, _status, _body}), do: :transient

  defp classify({:batch_request_failed, status, _body}) when status >= 400 and status < 500,
    do: :client_error

  defp classify({:batch_request_failed, _status, _body}), do: :transient

  # Tagged errors
  defp classify({:validation, _}), do: :client_error
  defp classify({:consent_revoked, _}), do: :client_error
  defp classify({:db_error, _}), do: :transient

  # Default
  defp classify(nil), do: :transient
  defp classify(_), do: :transient

  # Formatting

  defp format(%Req.TransportError{} = error), do: CommonError.format(error)

  # Permission errors (403) with helpful guidance
  defp format(%Req.Response{status: 403, body: %{"error" => error_obj}}) do
    code = Map.get(error_obj, "code")

    base_message =
      case code do
        "Authorization_RequestDenied" -> "Insufficient permissions"
        "Forbidden" -> "Access forbidden"
        _ -> "Permission denied"
      end

    "#{base_message}. Please verify the Firezone Directory Sync app has the required permissions " <>
      "(Directory.Read.All, User.Read.All, and Application.Read.All) in Microsoft Entra and re-grant admin consent."
  end

  # Authentication errors (401) with helpful guidance
  defp format(%Req.Response{status: 401, body: %{"error" => _error_obj}}) do
    "Authentication failed. The app credentials may have expired or been revoked. " <>
      "Please re-grant admin consent in Microsoft Entra."
  end

  # Generic error response with error object
  defp format(%Req.Response{status: status, body: %{"error" => error_obj}}) do
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

  # 403 without error object
  defp format(%Req.Response{status: 403}) do
    "Permission denied. Please verify the Firezone Directory Sync app has the required permissions " <>
      "in Microsoft Entra and re-grant admin consent."
  end

  # 401 without error object
  defp format(%Req.Response{status: 401}) do
    "Authentication failed. Please re-grant admin consent in Microsoft Entra."
  end

  # Response with binary body
  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  # Generic response
  defp format(%Req.Response{status: status}) do
    "Entra API returned HTTP #{status}"
  end

  # Batch errors - treat as responses for formatting
  defp format({:batch_all_failed, status, body}) do
    format(%Req.Response{status: status, body: body})
  end

  defp format({:batch_request_failed, status, body}) do
    format(%Req.Response{status: status, body: body})
  end

  # Tagged errors
  defp format({:validation, msg}), do: msg
  defp format({:consent_revoked, msg}), do: msg
  defp format({:db_error, error}), do: CommonError.format(error)

  # nil context
  defp format(nil), do: "Unknown error occurred"

  # String context (pass through)
  defp format(msg) when is_binary(msg), do: msg

  # Everything else
  defp format(error), do: CommonError.format(error)

  defp format_generic_error(error) when is_exception(error), do: Exception.message(error)
  defp format_generic_error(error), do: inspect(error)

  # Directory updates

  defp update_directory(directory_id, error_type, error_message) do
    now = DateTime.utc_now()

    case Database.get_directory(directory_id) do
      nil ->
        Logger.info("Directory not found, skipping error update",
          provider: :entra,
          directory_id: directory_id
        )

        :ok

      directory ->
        do_update_directory(directory, error_type, error_message, now)
    end
  end

  defp do_update_directory(directory, :client_error, error_message, now) do
    changeset =
      Ecto.Changeset.cast(
        directory,
        %{
          "errored_at" => now,
          "error_message" => error_message,
          "is_disabled" => true,
          "disabled_reason" => "Sync error",
          "is_verified" => false
        },
        [:errored_at, :error_message, :is_disabled, :disabled_reason, :is_verified]
      )

    {:ok, _directory} = Database.update_directory(changeset)
  end

  defp do_update_directory(directory, :transient, error_message, now) do
    errored_at = directory.errored_at || now
    hours_since_error = DateTime.diff(now, errored_at, :hour)
    should_disable = hours_since_error >= 24

    attrs = %{
      "errored_at" => errored_at,
      "error_message" => error_message
    }

    attrs =
      if should_disable do
        Map.merge(attrs, %{
          "is_disabled" => true,
          "disabled_reason" => "Sync error",
          "is_verified" => false
        })
      else
        attrs
      end

    changeset =
      Ecto.Changeset.cast(directory, attrs, [
        :errored_at,
        :error_message,
        :is_disabled,
        :disabled_reason,
        :is_verified
      ])

    {:ok, _directory} = Database.update_directory(changeset)
  end

  # Sentry context building

  defp build_sentry_context(
         %__MODULE__{error: error, directory_id: directory_id, step: step},
         job
       ) do
    job
    |> Map.take([:id, :args, :meta, :queue, :worker])
    |> Map.put(:directory_id, directory_id)
    |> Map.put(:step, step)
    |> Map.put(:error, inspect(error))
  end

  defp build_default_sentry_context(job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
  end
end
