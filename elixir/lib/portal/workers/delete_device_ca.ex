defmodule Portal.Workers.DeleteDeviceCA do
  @moduledoc """
  Deletes the device CA key of a deleted account. The account delete queues it in the same
  transaction.
  """
  use Oban.Worker,
    queue: :device_ca,
    max_attempts: 20,
    unique: [period: :infinity, states: :incomplete, keys: [:account_id]]

  def insert(account_id), do: %{account_id: account_id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    Portal.DeviceCA.delete_key(account_id)
  end
end
