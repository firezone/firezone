defmodule Portal.Workers.DeleteOldOutboundEmailEntries do
  @moduledoc """
  Oban worker that prunes outbound email rows older than 30 days.
  Runs daily at midnight.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.Database

  @impl Oban.Worker
  def perform(_job) do
    Database.delete_older_than(30)
    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, OutboundEmail}

    def delete_older_than(days) do
      from(e in OutboundEmail,
        where: e.inserted_at < ago(^days, "day")
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
