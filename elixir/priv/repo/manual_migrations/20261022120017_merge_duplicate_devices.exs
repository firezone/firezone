Code.require_file("../migrations/helpers/device_merge.exs", __DIR__)

defmodule Portal.Repo.Migrations.MergeDuplicateDevices do
  @moduledoc """
  Folds device rows that describe one machine into one, so a device can be
  keyed by its firezone_id or certificate alone. See
  `Portal.Repo.Migrations.DeviceMerge` for what moves and for the dry run
  to look at first.
  """
  use Ecto.Migration

  require Logger

  # Each group merges in its own transaction so a failure leaves the groups
  # before it merged and the rest untouched for a rerun.
  @disable_ddl_transaction true

  def up do
    execute(fn ->
      %{merged: merged, skipped: skipped} = Portal.Repo.Migrations.DeviceMerge.merge_all()

      Logger.info("Merged #{length(merged)} duplicate device groups")

      for group <- skipped do
        Logger.warning(
          "Skipped a duplicate device group mixing client and gateway rows",
          account_id: group.account_id,
          key: group.key,
          slugs: Enum.map_join([group.winner | group.losers], ",", & &1.slug)
        )
      end
    end)
  end

  # The deleted rows are gone; nothing to restore.
  def down, do: :ok
end
