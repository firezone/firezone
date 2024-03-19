defmodule Domain.Flows.Activity.Query do
  use Domain, :query

  def all do
    from(activities in Domain.Flows.Activity, as: :activities)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [activities: activities], activities.account_id == ^account_id)
  end

  def by_flow_id(queryable, flow_id) do
    where(queryable, [activities: activities], activities.flow_id == ^flow_id)
  end

  def by_window_started_at(queryable, {:less_than, datetime}) do
    where(queryable, [activities: activities], activities.window_started_at < ^datetime)
  end

  def by_window_ended_at(queryable, {:greater_than, datetime}) do
    where(queryable, [activities: activities], activities.window_ended_at > ^datetime)
  end

  def first(queryable) do
    limit(queryable, 1)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:activities, :asc, :window_started_at},
      {:activities, :asc, :id}
    ]
end
