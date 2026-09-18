defmodule Portal.RepoQueryHelpers do
  @moduledoc """
  Captures the SQL the test process runs, so a test can pin which statements
  share a transaction.
  """

  @boundaries ["begin", "commit", "rollback"]

  def capture_queries(fun) do
    fun |> capture_statements() |> Enum.map(&elem(&1, 0))
  end

  @doc """
  The SQL the test process ran while `fun` ran, each with its parameters.
  """
  def capture_statements(fun) do
    test_pid = self()
    handler_id = "queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:portal, :repo, :query],
      fn _event, _measurements, %{query: query, params: params}, _config ->
        if self() == test_pid do
          send(test_pid, {:query, query, params})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_queries([])
  end

  @doc """
  The plan Postgres picks for a captured statement once sequential scans are
  ruled out, so a test can pin the index a predicate is meant to use.
  """
  def indexed_plan(sql, params) do
    Portal.Repo.query!("SET LOCAL enable_seqscan = off")
    %{rows: rows} = Portal.Repo.query!("EXPLAIN " <> sql, params)
    Enum.map_join(rows, "\n", &hd/1)
  end

  @doc """
  Whether the first statement containing `first` and the next one containing
  `last` ran inside one transaction.
  """
  def one_transaction?(queries, first, last) do
    {before, from_first} = Enum.split_while(queries, &(not String.contains?(&1, first)))

    {between, from_last} =
      from_first
      |> Enum.drop(1)
      |> Enum.split_while(&(not String.contains?(&1, last)))

    from_last != [] and
      before |> Enum.reverse() |> Enum.find(&(&1 in @boundaries)) == "begin" and
      not Enum.any?(between, &(&1 in @boundaries))
  end

  defp collect_queries(acc) do
    receive do
      {:query, query, params} -> collect_queries([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
