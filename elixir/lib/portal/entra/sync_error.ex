defmodule Portal.Entra.SyncError do
  @moduledoc """
  Wrapper exception for Entra directory sync failures.

  This exception wraps the underlying context and adds the directory_id
  and sync step that are extracted by the Oban telemetry reporter and sent to Sentry.

  The `reason` field is a human-readable message, while `context` preserves
  structured error context for classification and debugging.
  """

  defexception [:message, :reason, :context, :directory_id, :step]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    context = Keyword.get(opts, :context)
    directory_id = Keyword.fetch!(opts, :directory_id)
    step = Keyword.fetch!(opts, :step)

    message = build_message(reason, directory_id, step)

    %__MODULE__{
      message: message,
      reason: reason,
      context: context,
      directory_id: directory_id,
      step: step
    }
  end

  defp build_message(reason, directory_id, step) when is_binary(reason) do
    "Entra sync failed for directory #{directory_id} at #{step}: #{reason}"
  end

  defp build_message(%{status: status, body: body}, directory_id, step) when is_integer(status) do
    "Entra sync failed for directory #{directory_id} at #{step}: HTTP #{status} - #{inspect(body)}"
  end

  defp build_message(%{__exception__: true} = exception, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: #{Exception.message(exception)}"
  end

  defp build_message(reason, directory_id, step) do
    "Entra sync failed for directory #{directory_id} at #{step}: #{inspect(reason)}"
  end
end
