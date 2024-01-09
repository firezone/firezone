defmodule Domain.Tokens.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  alias Domain.Tokens
  require Logger

  every minutes(5), :delete_expired_tokens do
    {:ok, _count} = Tokens.delete_expired_tokens()
    :ok
  end
end
