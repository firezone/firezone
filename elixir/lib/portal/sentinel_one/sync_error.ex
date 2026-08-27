defmodule Portal.SentinelOne.SyncError do
  defexception [:message, :error, :provider_id, :step]

  @impl true
  def exception(opts) do
    provider_id = Keyword.fetch!(opts, :provider_id)
    step = Keyword.fetch!(opts, :step)
    error = Keyword.get(opts, :error)

    %__MODULE__{
      provider_id: provider_id,
      step: step,
      error: error,
      message:
        "SentinelOne sync failed for provider #{provider_id} at #{step}: #{inspect(error)}"
    }
  end
end
