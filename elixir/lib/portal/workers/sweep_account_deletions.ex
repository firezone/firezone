defmodule Portal.Workers.SweepAccountDeletions do
  @moduledoc """
  Cron worker that sweeps accounts due for deletion and enqueues a DeleteAccount job for each.
  Runs every minute. The DeleteAccount unique constraint prevents duplicate jobs per account.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :executing]]

  alias Portal.Workers.DeleteAccount
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    account_ids = Database.fetch_accounts_due_for_deletion()

    Logger.info("Sweeping accounts due for deletion", count: length(account_ids))

    Enum.each(account_ids, fn account_id ->
      %{"account_id" => account_id}
      |> DeleteAccount.new()
      |> Oban.insert()
    end)

    :ok
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Account
    alias Portal.Safe

    # Safe.all/1 return type cannot be narrowed through Ecto query macros by dialyzer
    @dialyzer {:nowarn_function, fetch_accounts_due_for_deletion: 0}

    @spec fetch_accounts_due_for_deletion() :: [binary()]
    def fetch_accounts_due_for_deletion do
      now = DateTime.utc_now()

      from(a in Account,
        where: not is_nil(a.disabled_at),
        where: not is_nil(a.scheduled_deletion_at),
        where: a.scheduled_deletion_at <= ^now,
        select: a.id
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end
  end
end
