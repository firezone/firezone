defmodule Portal.Workers.DeleteAccount do
  @moduledoc """
  Oban worker that hard-deletes a single account once its scheduled deletion time is due.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable],
      keys: [:account_id]
    ]

  alias Portal.Account
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    case Database.fetch_account(account_id) do
      nil ->
        :ok

      %Account{} = account ->
        maybe_delete_account(account)
    end
  end

  defp maybe_delete_account(%Account{} = account) do
    cond do
      is_nil(account.scheduled_deletion_at) ->
        :ok

      is_nil(account.disabled_at) ->
        :ok

      DateTime.compare(account.scheduled_deletion_at, DateTime.utc_now()) == :gt ->
        :ok

      true ->
        Logger.info("Hard-deleting account pending deletion", account_id: account.id)
        Database.delete_account(account)
        :ok
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Account
    alias Portal.Safe

    def fetch_account(account_id) do
      from(a in Account, where: a.id == ^account_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def delete_account(%Account{} = account) do
      account
      |> Safe.unscoped()
      |> Safe.delete()
    end
  end
end
