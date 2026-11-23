defmodule Portal.MetricsFixtures do
  @moduledoc """
  Test helpers for setting the metric name patterns of plans and accounts, and
  the diagnostics of actors.
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

  def metrics_diagnostics_fixture(actor, expires_at \\ DateTime.add(DateTime.utc_now(), 1, :day)) do
    %Portal.MetricsDiagnostics{}
    |> Ecto.Changeset.cast(
      %{account_id: actor.account_id, actor_id: actor.id, expires_at: expires_at},
      [:account_id, :actor_id, :expires_at]
    )
    |> Portal.MetricsDiagnostics.changeset()
    |> Portal.Repo.insert!(
      on_conflict: {:replace, [:expires_at, :updated_at]},
      conflict_target: [:account_id, :actor_id]
    )
  end
end
