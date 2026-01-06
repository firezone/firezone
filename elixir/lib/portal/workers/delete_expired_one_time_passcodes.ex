defmodule Portal.Workers.DeleteExpiredOneTimePasscodes do
  @moduledoc """
  Oban worker that deletes expired one-time passcodes.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.DB

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = DB.delete_expired_passcodes()

    Logger.info("Deleted #{count} expired one-time passcodes")

    :ok
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.OneTimePasscode
    alias Portal.Safe

    def delete_expired_passcodes do
      from(p in OneTimePasscode, as: :passcodes)
      |> where([passcodes: p], p.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
