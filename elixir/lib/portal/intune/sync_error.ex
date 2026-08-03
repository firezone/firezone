defmodule Portal.Intune.SyncError do
  defexception [:message, :error, :integration_id, :step]

  @impl true
  def exception(opts) do
    integration_id = Keyword.fetch!(opts, :integration_id)
    step = Keyword.fetch!(opts, :step)
    error = Keyword.get(opts, :error)

    %__MODULE__{
      integration_id: integration_id,
      step: step,
      error: error,
      message:
        "Intune sync failed for integration #{integration_id} at #{step}: #{inspect(error)}"
    }
  end
end
