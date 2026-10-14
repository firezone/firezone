defmodule Portal.Workers.RollupAccountActivity do
  @moduledoc """
  Persists coalesced account activity using a durable incremental watermark.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(_job) do
    case Portal.Accounts.Inactivity.rollup() do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
