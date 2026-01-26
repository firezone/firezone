defmodule Portal.Workers.DeleteExpiredAPITokens do
  @moduledoc """
  Oban worker that deletes expired API tokens.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_expired_api_tokens()

    Logger.info("Deleted #{count} expired API tokens")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.APIToken
    alias Portal.Repo

    def delete_expired_api_tokens do
      from(t in APIToken, as: :api_tokens)
      |> where([api_tokens: t], t.expires_at <= ^DateTime.utc_now())
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()
    end
  end
end
