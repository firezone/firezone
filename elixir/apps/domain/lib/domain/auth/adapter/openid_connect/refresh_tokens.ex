defmodule Domain.Auth.Adapter.OpenIDConnect.RefreshTokens do
  require Logger

  def refresh_access_tokens(name, adapter) do
    providers = Domain.Auth.all_providers_pending_token_refresh_by_adapter!(name)
    Logger.debug("Refreshing access tokens for #{length(providers)} #{name} providers")

    Enum.each(providers, fn provider ->
      Logger.metadata(
        provider_id: provider.id,
        account_id: provider.account_id,
        adapter: name
      )

      Logger.debug("Refreshing access token")

      fn -> adapter.refresh_access_token(provider) end
      |> with_sync_retries()
      |> case do
        {:ok, _provider} ->
          Logger.debug("Finished refreshing access token")

        {:error, reason} ->
          Logger.error("Failed refreshing access token",
            provider: provider.id,
            reason: inspect(reason)
          )
      end
    end)
  end

  defp with_sync_retries(cb, retries_left \\ 3, retry_timeout \\ 100) do
    case cb.() do
      {:ok, result} ->
        {:ok, result}

      {:error, _reason} when retries_left > 0 ->
        Process.sleep(retry_timeout)
        with_sync_retries(cb, retries_left - 1, retry_timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
