defmodule Domain.Telemetry.Reporter.Log do
  use Domain, :schema

  schema "telemetry_reporter_logs" do
    field :reporter_module, :string
    field :last_flushed_at, :utc_datetime_usec

    timestamps()
  end
end
