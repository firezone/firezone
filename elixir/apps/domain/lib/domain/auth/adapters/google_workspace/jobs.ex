defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  require Logger

  every minutes(5), :refresh_access_tokens do
    Logger.debug("Refreshing tokens")
    :ok
  end
end
