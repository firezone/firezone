defmodule Portal.Repo.Batch do
  @moduledoc false

  alias __MODULE__.Database
  require Logger

  @type entry :: {map(), term()}
  @type fk_partition_kind :: :simple | :composite | :composite_optional
  @type fk_partition :: {fk_partition_kind(), atom(), module()}

  @spec insert_all(module(), [entry()], keyword()) :: {non_neg_integer(), [entry()]}
  def insert_all(schema, entries, opts \\ [])

  def insert_all(_schema, [], _opts), do: {0, []}

  def insert_all(schema, entries, opts) when is_list(entries) and is_list(opts) do
    config = %{
      label: Keyword.get(opts, :label, inspect(schema)),
      fk_partitions: Keyword.get(opts, :fk_partitions, %{})
    }

    do_insert_all(schema, entries, [], 0, config)
  end

  defp do_insert_all(_schema, [], failed, inserted, _config), do: {inserted, failed}

  defp do_insert_all(schema, entries, failed, inserted_acc, config) do
    attrs_list = Enum.map(entries, fn {attrs, _meta} -> attrs end)

    {inserted, _} = Database.insert_all(schema, attrs_list)

    {inserted_acc + inserted, failed}
  rescue
    error in [Postgrex.Error] ->
      case error.postgres do
        %{code: :foreign_key_violation, constraint: constraint} ->
          {valid, invalid} = partition_for_constraint(entries, constraint, config)
          do_insert_all(schema, valid, failed ++ invalid, inserted_acc, config)

        _ ->
          Logger.error(
            "Batch insert #{config.label} failed (#{length(entries)} entries): " <>
              Exception.message(error)
          )

          {inserted_acc, failed ++ entries}
      end

    error ->
      Logger.error(
        "Batch insert #{config.label} crashed (#{length(entries)} entries): " <>
          Exception.message(error)
      )

      {inserted_acc, failed ++ entries}
  catch
    kind, reason ->
      Logger.error(
        "Batch insert #{config.label} threw #{kind} (#{length(entries)} entries): " <>
          inspect(reason)
      )

      {inserted_acc, failed ++ entries}
  end

  defp partition_for_constraint(entries, constraint, config) do
    case Map.get(config.fk_partitions, constraint) do
      nil ->
        {[], entries}

      {:simple, key, schema} ->
        partition_by_simple(entries, key, schema)

      {:composite, key, schema} ->
        partition_by_composite(entries, key, schema)

      {:composite_optional, key, schema} ->
        {nil_entries, non_nil_entries} =
          Enum.split_with(entries, fn {attrs, _} -> is_nil(attrs[key]) end)

        {valid, invalid} = partition_by_composite(non_nil_entries, key, schema)
        {nil_entries ++ valid, invalid}
    end
  end

  defp partition_by_simple(entries, key, schema) do
    ids = entries |> Enum.map(fn {attrs, _} -> attrs[key] end) |> Enum.uniq()

    existing_ids = Database.existing_ids(schema, ids)

    Enum.split_with(entries, fn {attrs, _} ->
      MapSet.member?(existing_ids, attrs[key])
    end)
  end

  defp partition_by_composite(entries, key, schema) do
    ids_by_account =
      entries
      |> Enum.map(fn {attrs, _} -> {attrs[:account_id], attrs[key]} end)
      |> Enum.uniq()
      |> Enum.group_by(fn {account_id, _} -> account_id end, fn {_, id} -> id end)

    existing_pairs = Database.existing_pairs(schema, ids_by_account)

    Enum.split_with(entries, fn {attrs, _} ->
      MapSet.member?(existing_pairs, {attrs[:account_id], attrs[key]})
    end)
  end

  defmodule Database do
    @moduledoc false

    import Ecto.Query
    alias Portal.Safe

    def insert_all(schema, attrs_list) do
      Safe.unscoped()
      |> Safe.insert_all(schema, attrs_list)
    end

    def existing_ids(schema, ids) do
      from(t in schema, where: t.id in ^ids, select: t.id)
      |> Safe.unscoped()
      |> Safe.all()
      |> MapSet.new()
    end

    def existing_pairs(schema, ids_by_account) do
      conditions =
        Enum.reduce(ids_by_account, dynamic(false), fn {account_id, ids}, acc ->
          dynamic([t], ^acc or (t.account_id == ^account_id and t.id in ^ids))
        end)

      from(t in schema, where: ^conditions, select: {t.account_id, t.id})
      |> Safe.unscoped()
      |> Safe.all()
      |> MapSet.new()
    end
  end
end
