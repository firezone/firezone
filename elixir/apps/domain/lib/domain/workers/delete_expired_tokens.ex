defmodule Domain.Workers.DeleteExpiredTokens do
  @moduledoc """
  Oban worker that deletes expired tokens.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.DB

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = DB.delete_expired_tokens()

    Logger.info("Deleted #{count} expired tokens")

    :ok
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, Token}

    def delete_expired_tokens do
      from(t in Token, as: :tokens)
      |> where([tokens: t], t.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
