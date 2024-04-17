defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs.RefreshAccessTokens do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.GloballyUnique

  alias Domain.Auth.Adapters.GoogleWorkspace
  require Logger

  @impl true
  def execute(_config) do
    providers = Domain.Auth.all_providers_pending_token_refresh_by_adapter!(:google_workspace)
    Logger.debug("Refreshing access tokens for #{length(providers)} providers")

    Enum.each(providers, fn provider ->
      Logger.debug("Refreshing access token",
        provider_id: provider.id,
        account_id: provider.account_id
      )

      case GoogleWorkspace.refresh_access_token(provider) do
        {:ok, provider} ->
          Logger.debug("Finished refreshing access token",
            provider_id: provider.id,
            account_id: provider.account_id
          )

        {:error, reason} ->
          Logger.error("Failed refreshing access token",
            provider_id: provider.id,
            account_id: provider.account_id,
            reason: inspect(reason)
          )
      end
    end)
  end
end
