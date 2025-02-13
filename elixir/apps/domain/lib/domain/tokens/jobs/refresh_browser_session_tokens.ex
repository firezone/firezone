defmodule Domain.Tokens.Jobs.RefreshBrowserSessionTokens do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.GloballyUnique

  alias Domain.Repo
  alias Domain.Auth
  alias Domain.Tokens
  require Logger

  @impl true
  def execute(_config) do
    Tokens.all_active_browser_session_tokens!()
    |> Repo.preload(identity: :provider)
    |> Enum.each(fn token ->
      with {:ok, _identity, expires_at} when not is_nil(expires_at) <-
             Auth.Adapters.refresh_access_token(token.identity.provider, token.identity),
           {:ok, _token} <- Tokens.update_token(token, %{expires_at: expires_at}) do
        :ok
      else
        {:ok, _identity, nil} ->
          :ok

        {:error, :not_supported} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to refresh browser session token",
            token_id: token.id,
            identity_id: token.identity.id,
            provider_id: token.identity.provider_id,
            reason: inspect(reason)
          )

          :ok
      end
    end)
  end
end
