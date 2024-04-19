defmodule Domain.Tokens.Jobs.DeleteExpiredTokens do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.GloballyUnique

  alias Domain.Tokens
  require Logger

  @impl true
  def execute(_config) do
    {:ok, _count} = Tokens.delete_expired_tokens()
    :ok
  end
end
