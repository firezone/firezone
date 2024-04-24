defmodule Domain.Auth.Adapters.Okta.Jobs.RefreshAccessTokens do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.GloballyUnique

  @impl true
  def execute(_config) do
    Domain.Auth.Adapter.OpenIDConnect.RefreshTokens.refresh_access_tokens(
      :okta,
      Domain.Auth.Adapters.Okta
    )
  end
end
