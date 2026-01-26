defmodule Portal.Workers.DeleteExpiredOneTimePasscodes do
  @moduledoc """
  Oban worker that deletes expired one-time passcodes.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_expired_passcodes()

    Logger.info("Deleted #{count} expired one-time passcodes")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.OneTimePasscode
    alias Portal.Repo

    def delete_expired_passcodes do
      from(p in OneTimePasscode, as: :passcodes)
      |> where([passcodes: p], p.expires_at <= ^DateTime.utc_now())
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()
    end
  end
end
