defmodule Portal.DirectorySync.ErrorHandler do
  @moduledoc """
  Handles errors from directory sync Oban jobs (Entra, Google, Okta).

  This module orchestrates error handling by:
  - Delegating to provider-specific error formatters
  - Updating directory state based on error type
  - Building Sentry context for error reporting

  Error handling strategy:
  - 4xx HTTP errors: Disable directory immediately (user action required)
  - 5xx HTTP errors: Record error, disable after 24 hours (transient)
  - Network/transport errors: Treat as transient (5xx behavior)
  - Validation errors: Disable directory immediately (user action required)
  - Missing scopes: Disable directory immediately (user action required)
  - Circuit breaker: Disable directory immediately (user action required)
  - Other errors: Treat as transient (5xx behavior)
  """

  alias __MODULE__.Database
  alias Portal.DirectorySync.ErrorFormatter
  require Logger

  # Re-export format_transport_error for backwards compatibility
  defdelegate format_transport_error(error), to: ErrorFormatter

  @doc """
  Handle an error from a directory sync job.

  Extracts the directory_id from job args, delegates to provider-specific handling,
  and returns extra context for Sentry reporting.
  """
  def handle_error(%{reason: reason, job: job}) do
    directory_id = job.args["directory_id"]

    case job.worker do
      "Portal.Entra.Sync" -> handle_provider_error(Portal.Entra, reason, directory_id)
      "Portal.Google.Sync" -> handle_provider_error(Portal.Google, reason, directory_id)
      "Portal.Okta.Sync" -> handle_provider_error(Portal.Okta, reason, directory_id)
      _ -> :ok
    end

    build_sentry_context(reason, job)
  end

  # Provider error handling

  defp handle_provider_error(Portal.Entra, %Portal.Entra.SyncError{context: context}, dir_id) do
    {error_type, message} = Portal.Entra.ErrorFormatter.classify_and_format(context)
    update_directory(:entra, dir_id, error_type, message)
  end

  defp handle_provider_error(Portal.Entra, error, directory_id) do
    message = Portal.Entra.ErrorFormatter.format_generic_error(error)
    update_directory(:entra, directory_id, :transient, message)
  end

  defp handle_provider_error(Portal.Google, %Portal.Google.SyncError{context: context}, dir_id) do
    {error_type, message} = Portal.Google.ErrorFormatter.classify_and_format(context)
    update_directory(:google, dir_id, error_type, message)
  end

  defp handle_provider_error(Portal.Google, error, directory_id) do
    message = Portal.Google.ErrorFormatter.format_generic_error(error)
    update_directory(:google, directory_id, :transient, message)
  end

  defp handle_provider_error(Portal.Okta, %Portal.Okta.SyncError{context: context}, dir_id) do
    {error_type, message} = Portal.Okta.ErrorFormatter.classify_and_format(context)
    update_directory(:okta, dir_id, error_type, message)
  end

  defp handle_provider_error(Portal.Okta, error, directory_id) do
    message = Portal.Okta.ErrorFormatter.format_generic_error(error)
    update_directory(:okta, directory_id, :transient, message)
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
           context: context,
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
    |> Map.put(:context, inspect(context))
  end

  defp build_sentry_context(_reason, job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
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
