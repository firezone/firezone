defmodule Domain.ChangeLogs do
  alias Domain.ChangeLogs.ChangeLog
  alias Domain.Repo

  def bulk_insert(list_of_attrs) do
    ChangeLog
    |> Repo.insert_all(list_of_attrs,
      on_conflict: :nothing,
      conflict_target: [:lsn]
    )
  end
end
