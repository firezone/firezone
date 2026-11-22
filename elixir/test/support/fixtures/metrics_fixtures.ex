defmodule Portal.MetricsFixtures do
  @moduledoc """
  Test helpers for setting the metric name patterns of plans and accounts.
  """

  def plan_metrics_fixture(plan, patterns) do
    %Portal.PlanMetrics{}
    |> Ecto.Changeset.cast(%{plan: to_string(plan), patterns: patterns}, [:plan, :patterns])
    |> Portal.PlanMetrics.changeset()
    |> Portal.Repo.insert!(on_conflict: {:replace, [:patterns, :updated_at]}, conflict_target: :plan)
  end

  def account_metrics_fixture(account, patterns) do
    %Portal.AccountMetrics{}
    |> Ecto.Changeset.cast(%{account_id: account.id, patterns: patterns}, [:account_id, :patterns])
    |> Portal.AccountMetrics.changeset()
    |> Portal.Repo.insert!(
      on_conflict: {:replace, [:patterns, :updated_at]},
      conflict_target: :account_id
    )
  end
end
