defmodule Domain.Tokens.Workers.DeleteExpiredTokens do
  @moduledoc """
  Oban worker that deletes expired tokens.
  Runs every 5 minutes.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300]

  alias Domain.Tokens
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {:ok, _count} = Tokens.delete_expired_tokens()
    :ok
  end
end
