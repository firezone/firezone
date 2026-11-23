defmodule Portal.Workers.ProvisionMissingDeviceCAs do
  @moduledoc """
  Queues the device CA job for each account that has no CA yet, disabled or not. This backfills
  existing accounts and catches any account whose insert job was lost.
  """
  use Oban.Worker,
    queue: :device_ca,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database
  alias Portal.Workers.ProvisionDeviceCA

  @batch_size 1_000

  @impl Oban.Worker
  def perform(_job) do
    Database.account_ids_without_ca(@batch_size)
    |> Enum.each(fn account_id ->
      {:ok, _job} = %{account_id: account_id} |> ProvisionDeviceCA.new() |> Oban.insert()
    end)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Account, DeviceCertificateAuthority, Safe}

    def account_ids_without_ca(limit) do
      from(a in Account,
        left_join: ca in DeviceCertificateAuthority,
        on: ca.account_id == a.id,
        where: is_nil(ca.account_id),
        order_by: a.id,
        limit: ^limit,
        select: a.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
