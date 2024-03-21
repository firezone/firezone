defmodule Domain.Auth.Adapter.DirectorySync do
  defp load_providers_pending_sync(adapter) do
    providers = Domain.Auth.all_providers_pending_sync_by_adapter!(adapter)
    Logger.debug("Syncing #{length(providers)} #{adapter} providers", adapter: adapter)
  end
end
