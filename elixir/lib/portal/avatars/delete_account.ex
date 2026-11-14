defmodule Portal.Avatars.DeleteAccount do
  @moduledoc """
  Oban worker that deletes every profile photo of a deleted account. The
  account delete queues it in the same transaction.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity, states: :incomplete, keys: [:account_id]]

  alias Portal.Avatars

  @doc """
  Queues the job, unless photos are off.
  """
  def insert(account_id) do
    if Avatars.enabled?() do
      %{account_id: account_id} |> new() |> Oban.insert()
    else
      {:ok, nil}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    if Avatars.enabled?() do
      Avatars.delete_account(account_id)
    end

    :ok
  end
end
