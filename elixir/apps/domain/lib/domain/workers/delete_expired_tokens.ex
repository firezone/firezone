defmodule Domain.Workers.DeleteExpiredTokens do
  @moduledoc """
  Oban worker that deletes expired tokens.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity]

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = delete_expired_tokens()

    Logger.info("Deleted #{count} expired tokens")

    :ok
  end

  # Inline function from Domain.Tokens
  defp delete_expired_tokens do
    import Ecto.Query

    from(t in Domain.Token, as: :tokens)
    |> where([tokens: t], t.expires_at <= ^DateTime.utc_now())
    |> Domain.Safe.unscoped()
    |> Domain.Safe.delete_all()
  end
end
