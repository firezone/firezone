defmodule Portal.Workers.AccountInactivityReminder do
  @moduledoc """
  Rechecks inactivity and sends one reminder through the existing outbound
  queue. The grace period starts only after the adapter accepts the message.
  """
  use Oban.Worker,
    queue: :outbound_emails,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:account_id]]

  @impl Oban.Worker
  def perform(job) do
    case Portal.Accounts.Inactivity.deliver_reminder(job) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
