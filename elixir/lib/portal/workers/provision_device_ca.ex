defmodule Portal.Workers.ProvisionDeviceCA do
  @moduledoc """
  Creates the device CA of an account, with retries. Enqueued when an account is created.
  """
  use Oban.Worker,
    queue: :device_ca,
    max_attempts: 20,
    unique: [period: :infinity, states: :incomplete, keys: [:account_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    case Portal.DeviceCA.ensure(account_id) do
      {:ok, _ca} -> :ok
      {:error, %Ecto.Changeset{}} -> {:cancel, :account_deleted}
      {:error, :not_found} -> {:cancel, :account_deleted}
      {:error, :no_key_storage} -> {:cancel, :no_key_storage}
      {:error, reason} -> {:error, reason}
    end
  end
end
