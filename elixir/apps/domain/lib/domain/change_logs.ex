defmodule Domain.ChangeLogs do
  alias Domain.ChangeLogs.ChangeLog
  alias Domain.Repo

  def bulk_insert(list_of_attrs) do
    list_of_attrs =
      list_of_attrs
      |> Enum.map(&populate_account_id/1)
      |> Enum.filter(& &1.account_id)

    ChangeLog
    |> Repo.insert_all(list_of_attrs,
      on_conflict: :nothing,
      conflict_target: [:lsn],
      returning: [:lsn]
    )
  end

  defp populate_account_id(%{table: "accounts"} = attrs) do
    Map.put(attrs, :account_id, attrs.data["id"] || attrs.old_data["id"])
  end

  defp populate_account_id(%{table: _} = attrs) do
    Map.put(attrs, :account_id, attrs.data["account_id"] || attrs.old_data["account_id"])
  end

  defp populate_account_id(attrs), do: attrs
end
