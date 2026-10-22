defmodule Portal.Intune.SyncError do
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
        "Intune sync failed for provider #{provider_id} at #{step}: #{inspect(error)}"
    }
  end

  @doc """
  Whether Graph accepted the token but Intune refused to serve devices with it.

  The token endpoint is excluded: it reports a bad tenant or a missing service
  principal, neither of which resolves by waiting.
  """
  @spec graph_access_denied?(term()) :: boolean()
  def graph_access_denied?(%__MODULE__{
        step: :list_managed_devices,
        error: %Req.Response{status: status}
      })
      when status in [401, 403],
      do: true

  def graph_access_denied?(_reason), do: false
end
