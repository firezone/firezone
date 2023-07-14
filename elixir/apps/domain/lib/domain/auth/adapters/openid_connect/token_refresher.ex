defmodule Domain.Auth.Adapters.OpenIDConnect.TokenRefresher do
  use Domain.Jobs.Recurrent, otp_app: :domain
  require Logger

  every seconds(1), :refresh_tokens do
    Logger.info("Refreshing tokens")
  end
end
