defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs.RefreshAccessTokens do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.GloballyUnique

  @impl true
  def execute(_config) do
    Domain.Auth.Adapter.OpenIDConnect.RefreshTokens.refresh_access_tokens(
      :google_workspace,
      Domain.Auth.Adapters.GoogleWorkspace
    )
  end
end
