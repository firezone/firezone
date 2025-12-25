defmodule Portal.Workers.DeleteExpiredAPITokens do
  @moduledoc """
  Oban worker that deletes expired API tokens.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.DB

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = DB.delete_expired_api_tokens()

    Logger.info("Deleted #{count} expired API tokens")

    :ok
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.APIToken
    alias Portal.Safe

    def delete_expired_api_tokens do
      from(t in APIToken, as: :api_tokens)
      |> where([api_tokens: t], t.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
