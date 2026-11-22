defmodule Portal.PlanMetricsTest do
  use Portal.DataCase, async: true

  describe "changeset/1" do
    test "requires a known plan and at least one pattern" do
      assert errors_on(plan_metrics_changeset(%{plan: "gold", patterns: ["a"]})) == %{plan: ["is invalid"]}

      assert errors_on(plan_metrics_changeset(%{plan: "team", patterns: []})) == %{
               patterns: ["should have at least 1 item(s)"]
             }

      assert plan_metrics_changeset(%{plan: "team", patterns: ["a"]}).valid?
    end
  end

  defp plan_metrics_changeset(attrs) do
    %Portal.PlanMetrics{}
    |> cast(attrs, [:plan, :patterns])
    |> Portal.PlanMetrics.changeset()
  end
end
