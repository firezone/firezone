defmodule Portal.Workers.DeleteAccountsPendingDeletion do
  @moduledoc """
  Oban worker that hard-deletes accounts that have passed their scheduled deletion date.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    accounts = Database.fetch_accounts_pending_deletion()

    Enum.each(accounts, fn account ->
      Logger.info("Hard-deleting account pending deletion", account_id: account.id)
      Database.delete_account(account)
    end)

    Logger.info("Deleted #{length(accounts)} accounts pending deletion")
    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Account
    alias Portal.Safe

    @spec fetch_accounts_pending_deletion() :: [Account.t()]
    def fetch_accounts_pending_deletion do
      from(a in Account)
      |> where([a], not is_nil(a.scheduled_deletion_at))
      |> where([a], a.scheduled_deletion_at <= ^DateTime.utc_now())
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end

    @spec delete_account(Account.t()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
    def delete_account(%Account{} = account) do
      account
      |> Safe.unscoped()
      |> Safe.delete()
    end
  end
end
