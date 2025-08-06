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
  # this likely is not a major issue since our replication lag should be very low. The "fix" is to
  # determine the commit_timestamp for each entry and save that as well.
  def before_cutoff(queryable, %DateTime{} = cutoff) do
    queryable
    |> where([c], c.inserted_at < ^cutoff)
  end
end
