defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain

  every minutes(5), :refresh_access_tokens do
    :ok
  end
end
