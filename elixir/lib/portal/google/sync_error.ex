defmodule Portal.Google.SyncError do
  @moduledoc """
  Exception and error handling for Google Workspace directory sync.

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
      from(d in Portal.Google.Directory, where: d.id == ^directory_id)
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
    "Google sync failed for directory #{directory_id} at #{step}: HTTP #{status} - #{inspect(body)}"
  end

  defp build_message(%Req.TransportError{} = error, directory_id, step) do
    "Google sync failed for directory #{directory_id} at #{step}: #{Exception.message(error)}"
  end

  defp build_message({:validation, msg}, directory_id, step) do
    "Google sync failed for directory #{directory_id} at #{step}: #{msg}"
  end

  defp build_message({:db_error, error}, directory_id, step) do
    "Google sync failed for directory #{directory_id} at #{step}: database error: #{inspect(error)}"
  end

  defp build_message(%{__exception__: true} = exception, directory_id, step) do
    "Google sync failed for directory #{directory_id} at #{step}: #{Exception.message(exception)}"
  end

  defp build_message(error, directory_id, step) when is_binary(error) do
    "Google sync failed for directory #{directory_id} at #{step}: #{error}"
  end

  defp build_message(error, directory_id, step) do
    "Google sync failed for directory #{directory_id} at #{step}: #{inspect(error)}"
  end

  # Public API for Oban telemetry reporter

  @doc """
  Handle an error from a Google sync job.

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

  # Tagged errors
  defp classify({:validation, _}), do: :client_error
  defp classify({:db_error, _}), do: :transient

  # Default
  defp classify(nil), do: :transient
  defp classify(_), do: :transient

  # Formatting

  defp format(%Req.TransportError{} = error), do: CommonError.format(error)

  # Error response with error object
  defp format(%Req.Response{status: status, body: %{"error" => error_obj}})
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

  # Response with binary body
  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  # Generic response
  defp format(%Req.Response{status: status}) do
    "Google API returned HTTP #{status}"
  end

  # Tagged errors
  defp format({:validation, msg}), do: msg
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
          provider: :google,
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
