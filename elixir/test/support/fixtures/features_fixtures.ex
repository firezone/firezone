defmodule Portal.FeaturesFixtures do
  @moduledoc """
  Test helpers for managing global feature flags.
  """

  def enable_feature(feature) do
    Portal.Repo.insert!(%Portal.Features{feature: feature, enabled: true},
      on_conflict: {:replace, [:enabled]},
      conflict_target: [:feature]
    )
  end

  def disable_feature(feature) do
    Portal.Repo.insert!(%Portal.Features{feature: feature, enabled: false},
      on_conflict: {:replace, [:enabled]},
      conflict_target: [:feature]
    )
  end
end
