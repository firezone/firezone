defmodule Domain.ChangeLogs.ChangeLog.Query do
  use Domain, :query

  def all do
    Domain.ChangeLogs.ChangeLog
  end

  def by_account_id(queryable, account_id) do
    queryable
    |> where([c], c.account_id == ^account_id)
  end

  # Note: This will return change_logs that were inserted before this date, which means it will
  # omit change_logs that were generated before the cut off but inserted after it. In practice,
  # this likely is not a major issue since:
  #   (1) our replication lag should be fairly low
  #   (2) at worst, we will omit changes older than the cut
  # 
  # The "fix" is to add a commit_timestamp to change_logs and use that instead.
  # However, that adds a non-trivial amount of complexity to the ingestion processor.
  def before_cutoff(queryable, %DateTime{} = cutoff) do
    queryable
    |> where([c], c.inserted_at < ^cutoff)
  end
end
