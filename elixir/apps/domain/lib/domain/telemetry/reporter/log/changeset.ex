defmodule Domain.Telemetry.Reporter.Log.Changeset do
  use Domain, :changeset

  def changeset(%Domain.Telemetry.Reporter.Log{} = log, attrs) do
    log
    |> cast(attrs, [:reporter_module, :last_flushed_at])
    |> validate_required([:reporter_module])
    |> unique_constraint(:reporter_module)
  end
end
