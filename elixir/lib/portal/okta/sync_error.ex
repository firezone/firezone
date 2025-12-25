defmodule Portal.Okta.SyncError do
  @moduledoc """
  Exception raised when Okta directory sync fails.

  This exception is captured by the Oban telemetry reporter and sent to Sentry
  with full context about the directory and the failure reason.
  """

  defexception [:message, :reason, :cause, :directory_id, :step]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    cause = Keyword.get(opts, :cause, reason)
    directory_id = Keyword.fetch!(opts, :directory_id)
    step = Keyword.fetch!(opts, :step)

    message = build_message(reason, directory_id, step)

    %__MODULE__{
      message: message,
      reason: reason,
      cause: cause,
      directory_id: directory_id,
      step: step
    }
  end

  defp build_message(reason, directory_id, step) when is_binary(reason) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{reason}"
  end

  defp build_message(%{status: status, body: body}, directory_id, step) when is_integer(status) do
    "Okta sync failed for directory #{directory_id} at #{step}: HTTP #{status} - #{inspect(body)}"
  end

  defp build_message(%{__exception__: true} = exception, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{Exception.message(exception)}"
  end

  defp build_message(reason, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{inspect(reason)}"
  end
end
