defmodule Domain.ChangeLogs do
  alias Domain.ChangeLogs.ChangeLog
  alias Domain.Repo

  def create_change_log(attrs) do
    attrs
    |> ChangeLog.Changeset.changeset()
    |> Repo.insert()
  end
end
