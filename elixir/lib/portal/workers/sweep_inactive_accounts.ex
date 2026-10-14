defmodule Portal.Workers.SweepInactiveAccounts do
  @moduledoc """
  Sweeps inactivity warnings and deletion deadlines without future lifecycle jobs.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(_job) do
    case Portal.Accounts.Inactivity.sweep() do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
