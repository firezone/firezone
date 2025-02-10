defmodule Domain.Telemetry.Reporter.Log.Query do
  use Domain, :query

  def all do
    from(log in Domain.Telemetry.Reporter.Log, as: :log)
  end

  def by_reporter_module(queryable, reporter_module) do
    where(queryable, [log: log], log.reporter_module == ^reporter_module)
  end
end
