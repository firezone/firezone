defmodule Portal.Workers.DeleteAccount do
  @moduledoc """
  Oban worker that hard-deletes a single account once its scheduled deletion conditions are met.
  Enqueued by SweepAccountDeletions.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:account_id]
    ]

  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    case Database.transact_delete(account_id) do
      {:ok, {:deleted, account}} ->
        Logger.info("Hard-deleted account pending deletion", account_id: account.id)
        :ok

      {:ok, :noop} ->
        Logger.info("DeleteAccount no-op: account already deleted or conditions cleared",
          account_id: account_id
        )

        :ok

      {:error, _} = error ->
        error
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Account
    alias Portal.Actor
    alias Portal.Safe
    alias Portal.Workers.AccountDeletionCompleted
    alias Portal.Workers.DeleteSubscription

    # Safe.all/1 return type cannot be narrowed through Ecto query macros by dialyzer
    @dialyzer {:nowarn_function, get_account_admin_emails: 1}

    @spec transact_delete(binary()) ::
            {:ok, {:deleted, Account.t()} | :noop} | {:error, term()}
    def transact_delete(account_id) do
      Safe.transact(fn ->
        admin_emails = get_account_admin_emails(account_id)

        case delete_account(account_id) do
          {1, [account]} -> schedule_post_deletion_jobs(account, admin_emails)
          {0, []} -> {:ok, :noop}
        end
      end)
    end

    defp schedule_post_deletion_jobs(account, admin_emails) do
      with {:ok, _} <- maybe_insert_delete_subscription_job(account),
           {:ok, _} <- insert_completion_job(account, admin_emails) do
        {:ok, {:deleted, account}}
      end
    end

    defp maybe_insert_delete_subscription_job(%Account{} = account) do
      customer_id =
        get_in(account, [Access.key(:metadata), Access.key(:stripe), Access.key(:customer_id)])

      if customer_id do
        %{"customer_id" => customer_id}
        |> DeleteSubscription.new()
        |> Oban.insert()
      else
        {:ok, nil}
      end
    end

    defp insert_completion_job(_account, []), do: {:ok, nil}

    defp insert_completion_job(%Account{} = account, admin_emails) do
      %{
        "account_id" => account.id,
        "account_slug" => account.slug,
        "admin_emails" => admin_emails
      }
      |> AccountDeletionCompleted.new()
      |> Oban.insert()
    end

    @spec get_account_admin_emails(binary()) :: [binary()]
    def get_account_admin_emails(account_id) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: is_nil(a.disabled_at),
        select: a.email
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    @spec delete_account(binary()) :: {non_neg_integer(), [Account.t()]}
    def delete_account(account_id) do
      now = DateTime.utc_now()

      from(a in Account,
        where: a.id == ^account_id,
        where: not is_nil(a.disabled_at),
        where: not is_nil(a.scheduled_deletion_at),
        where: a.scheduled_deletion_at <= ^now,
        select: a
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
