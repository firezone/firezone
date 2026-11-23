defmodule Portal.MetricsFixtures do
  @moduledoc """
  Test helpers for creating metrics rules.
  """

  def metrics_rule_fixture(attrs \\ %{}) do
    %Portal.MetricsRule{}
    |> Ecto.Changeset.cast(Enum.into(attrs, %{patterns: ["*"]}), [
      :match,
      :patterns,
      :label_devices,
      :export_interval_secs,
      :expires_at
    ])
    |> Portal.MetricsRule.changeset()
    |> Portal.Repo.insert!()
  end
end
