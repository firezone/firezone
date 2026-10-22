defmodule Portal.ChangeLogFixtures do
  @moduledoc """
  Test helpers for creating change_logs.
  """

  import Portal.AccountFixtures

  alias Portal.ChangeLog
  alias Portal.Repo
  alias Portal.Types.LogId

  def change_log_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()
    lsn = Map.get(attrs, :lsn, System.unique_integer([:positive, :monotonic]))

    row =
      attrs
      |> Map.drop([:account])
      |> Map.put_new(:log_id, LogId.build_change_log(System.os_time(:microsecond), lsn))
      |> Map.put_new(:account_id, account.id)
      |> Map.put_new(:lsn, lsn)
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> Map.put_new(:object, "accounts")
      |> Map.put_new(:operation, :insert)
      |> Map.put_new(:after, %{"id" => account.id})
      |> Map.put_new(:before, nil)
      |> Map.put_new(:subject, nil)
      |> Map.put_new(:vsn, 0)

    {1, [change_log]} = Repo.insert_all(ChangeLog, [row], returning: true)

    change_log
  end
end
