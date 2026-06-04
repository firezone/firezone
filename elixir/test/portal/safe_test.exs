defmodule Portal.SafeTest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures
  alias Portal.Safe
  alias Portal.Account

  defmodule FlakyReplica do
    @moduledoc false
    # Stands in for a read replica that drops its connection during a transient
    # outage, raising the same error Postgrex surfaces in production.
    def one(_query),
      do: raise(DBConnection.ConnectionError, "ssl recv (idle): closed")

    def exists?(_query),
      do: raise(DBConnection.ConnectionError, "ssl recv (idle): closed")
  end

  describe "fallback_to_primary on replica connection errors" do
    setup do
      account = account_fixture()
      query = from(a in Account, where: a.id == ^account.id)
      %{account: account, query: query}
    end

    test "one/2 falls back to the primary", %{account: account, query: query} do
      assert result =
               query
               |> Safe.unscoped(FlakyReplica)
               |> Safe.one(fallback_to_primary: true)

      assert result.id == account.id
    end

    test "one!/2 falls back to the primary", %{account: account, query: query} do
      assert result =
               query
               |> Safe.unscoped(FlakyReplica)
               |> Safe.one!(fallback_to_primary: true)

      assert result.id == account.id
    end

    test "exists?/2 falls back to the primary", %{query: query} do
      assert query
             |> Safe.unscoped(FlakyReplica)
             |> Safe.exists?(fallback_to_primary: true)
    end

    test "re-raises when fallback is disabled", %{query: query} do
      assert_raise DBConnection.ConnectionError, fn ->
        query
        |> Safe.unscoped(FlakyReplica)
        |> Safe.one()
      end
    end
  end
end
