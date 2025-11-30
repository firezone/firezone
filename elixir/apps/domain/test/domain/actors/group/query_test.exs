defmodule Domain.ActorGroup.QueryTest do
  use Domain.DataCase, async: true
  alias Domain.Repo
  alias Domain.ActorGroup

  describe "batch_upsert/4" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      %{
        account: account,
        provider: provider
      }
    end

    test "returns {:ok, %{upserted_groups: 0}} for empty list", %{
      account: account,
      provider: provider
    } do
      now = DateTime.utc_now()

      assert Group.Query.batch_upsert(account.id, provider.id, now, []) ==
               {:ok, %{upserted_groups: 0}}

      assert Repo.aggregate(Group, :count) == 0
    end

    test "creates new groups when they don't exist", %{
      account: account,
      provider: provider
    } do
      now = DateTime.utc_now()

      attrs_list = [
        %{name: "Engineering", provider_identifier: "eng-001"},
        %{name: "Marketing", provider_identifier: "mkt-001"},
        %{name: "Sales", provider_identifier: "sales-001"}
      ]

      assert {:ok, %{upserted_groups: 3}} =
               Group.Query.batch_upsert(account.id, provider.id, now, attrs_list)

      # Verify they're persisted in the database with correct attributes
      created_groups =
        Group.Query.all()
        |> Group.Query.by_account_id(account.id)
        |> Group.Query.by_provider_id(provider.id)
        |> Repo.all()

      assert length(created_groups) == 3

      for group <- created_groups do
        assert group.provider_id == provider.id
        assert group.account_id == account.id
        assert group.type == :static
        assert group.last_synced_at == now
        assert group.name in ["Engineering", "Marketing", "Sales"]
        assert group.provider_identifier in ["eng-001", "mkt-001", "sales-001"]
      end
    end

    test "updates existing groups when they already exist", %{
      account: account,
      provider: provider
    } do
      now1 = DateTime.utc_now()
      now2 = DateTime.add(now1, 60, :second)

      # First create some groups
      attrs_list1 = [
        %{name: "Old Engineering", provider_identifier: "eng-001"},
        %{name: "Old Marketing", provider_identifier: "mkt-001"}
      ]

      {:ok, %{upserted_groups: 2}} =
        Group.Query.batch_upsert(account.id, provider.id, now1, attrs_list1)

      # Now update them with new names
      attrs_list2 = [
        %{name: "New Engineering", provider_identifier: "eng-001"},
        %{name: "New Marketing", provider_identifier: "mkt-001"},
        %{name: "Sales", provider_identifier: "sales-001"}
      ]

      {:ok, %{upserted_groups: 3}} =
        Group.Query.batch_upsert(account.id, provider.id, now2, attrs_list2)

      # Fetch the updated groups to verify all attributes
      updated_groups =
        Group.Query.all()
        |> Group.Query.by_account_id(account.id)
        |> Group.Query.by_provider_id(provider.id)
        |> Repo.all()

      # Verify updates and new creation
      eng_group = Enum.find(updated_groups, &(&1.provider_identifier == "eng-001"))
      assert eng_group.name == "New Engineering"
      assert eng_group.last_synced_at == now2

      mkt_group = Enum.find(updated_groups, &(&1.provider_identifier == "mkt-001"))
      assert mkt_group.name == "New Marketing"
      assert mkt_group.last_synced_at == now2

      sales_group = Enum.find(updated_groups, &(&1.provider_identifier == "sales-001"))
      assert sales_group.name == "Sales"
      assert sales_group.last_synced_at == now2

      # Verify total count (2 updated, 1 new)
      assert length(updated_groups) == 3
    end

    test "preserves groups from different providers", %{
      account: account,
      provider: provider
    } do
      {other_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      now = DateTime.utc_now()

      # Create a group for another provider
      other_group =
        Fixtures.Actors.create_group(
          account: account,
          provider: other_provider,
          provider_identifier: "other-001"
        )

      # Batch upsert for our provider
      attrs_list = [
        %{name: "Engineering", provider_identifier: "eng-001"}
      ]

      {:ok, %{upserted_groups: 1}} =
        Group.Query.batch_upsert(account.id, provider.id, now, attrs_list)

      # Verify other provider's group is not affected
      assert Repo.get(Group, other_group.id)
      assert Repo.aggregate(Group, :count) == 2
    end

    test "preserves groups from different accounts", %{
      provider: provider
    } do
      other_account = Fixtures.Accounts.create_account()
      now = DateTime.utc_now()

      # Create a group for another account
      other_group =
        Fixtures.Actors.create_group(
          account: other_account,
          provider_identifier: "eng-001"
        )

      # Batch upsert for our account
      attrs_list = [
        %{name: "Engineering", provider_identifier: "eng-001"}
      ]

      {:ok, %{upserted_groups: 1}} =
        Group.Query.batch_upsert(provider.account_id, provider.id, now, attrs_list)

      # Verify other account's group is not affected
      assert Repo.get(Group, other_group.id)
      assert Repo.aggregate(Group, :count) == 2
    end
  end
end
