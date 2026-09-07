defmodule Portal.RepoQueryHelpers do
  @moduledoc """
  Captures the SQL the test process runs, so a test can pin which statements
  share a transaction.
  """

  @boundaries ["begin", "commit", "rollback"]

  def capture_queries(fun) do
    test_pid = self()
    handler_id = "queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:portal, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == test_pid do
          send(test_pid, {:query, query})
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
      {:query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
