defmodule Portal.Repo.OffsetPaginatorTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Portal.Repo.OffsetPaginator

  defmodule Query do
    def cursor_fields, do: [{:accounts, :desc, :inserted_at}]
  end

  test "descending fields default to nulls last" do
    sql = paginated_sql([])

    assert sql =~ ~s(ORDER BY a0."inserted_at" DESC NULLS LAST)
  end

  test "the natural null ordering can be requested explicitly" do
    sql = paginated_sql(order_by_nulls: :natural)

    assert sql =~ ~s(ORDER BY a0."inserted_at" DESC)
    refute sql =~ "NULLS LAST"
  end

  defp paginated_sql(init_opts) do
    {:ok, opts} = OffsetPaginator.init(Query, [], init_opts)

    query =
      from(account in Portal.Account, as: :accounts)
      |> OffsetPaginator.query(opts)

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Portal.Repo, query)
    sql
  end
end
