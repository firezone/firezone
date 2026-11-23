defmodule Portal.AccountMetricsTest do
  use Portal.DataCase, async: true
  import Portal.AccountMetrics, only: [effective_patterns: 1]
  import Portal.AccountFixtures
  import Portal.MetricsFixtures

  describe "effective_patterns/1" do
    test "is empty without any patterns" do
      assert effective_patterns(team_account_fixture()) == []
    end

    test "includes the patterns of the account's plan" do
      account = team_account_fixture()
      plan_metrics_fixture(:team, ["b", "a"])
      plan_metrics_fixture(:starter, ["c"])

      assert effective_patterns(account) == ["a", "b"]
    end

    test "includes the account's own patterns" do
      account = team_account_fixture()
      account_metrics_fixture(account, ["a"])
      account_metrics_fixture(account_fixture(), ["c"])

      assert effective_patterns(account) == ["a"]
    end

    test "is the sorted union of both lists without duplicates" do
      account = team_account_fixture()
      plan_metrics_fixture(:team, ["c", "a", "d"])
      account_metrics_fixture(account, ["d", "b", "a"])

      assert effective_patterns(account) == ["a", "b", "c", "d"]
    end
  end

  describe "changeset/1" do
    test "requires at least one pattern and an existing account" do
      changeset = account_metrics_changeset(%{account_id: account_fixture().id, patterns: []})
      assert errors_on(changeset) == %{patterns: ["should have at least 1 item(s)"]}

      assert {:error, changeset} = Repo.insert(account_metrics_changeset(%{account_id: Ecto.UUID.generate(), patterns: ["a"]}))
      assert errors_on(changeset) == %{account: ["does not exist"]}
    end
  end

  test "an account's patterns are deleted with it" do
    account = account_fixture()
    account_metrics_fixture(account, ["a"])

    Repo.delete!(account)

    assert Repo.aggregate(Portal.AccountMetrics, :count) == 0
  end

  defp account_metrics_changeset(attrs) do
    %Portal.AccountMetrics{}
    |> cast(attrs, [:account_id, :patterns])
    |> Portal.AccountMetrics.changeset()
  end
end
