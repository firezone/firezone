defmodule Domain.ChangeLogs do
  alias Domain.ChangeLogs.ChangeLog
  alias Domain.{Accounts, Repo}

  def bulk_insert(list_of_attrs) do
    ChangeLog
    |> Repo.insert_all(list_of_attrs,
      on_conflict: :nothing,
      conflict_target: [:lsn]
    )
  end

  def truncate(%Accounts.Account{} = account, %DateTime{} = cutoff) do
    ChangeLog.Query.all()
    |> ChangeLog.Query.by_account_id(account.id)
    |> ChangeLog.Query.before_cutoff(cutoff)
    |> Repo.delete_all()
  end
end
