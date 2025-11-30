defmodule Domain.Membership.QueryTest do
  use Domain.DataCase, async: true
  alias Domain.Repo
  alias Domain.Membership

  describe "batch_upsert/4" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      # Create groups
      group1 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "group-001"
        )

      group2 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "group-002"
        )

      # Create identities with actors
      identity1 =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "user-001",
          actor: [type: :account_user, account: account]
        )

      identity2 =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "user-002",
          actor: [type: :account_user, account: account]
        )

      %{
        account: account,
        provider: provider,
        groups: [group1, group2],
        identities: [identity1, identity2]
      }
    end

    test "returns {:ok, %{upserted_memberships: 0}} for empty list", %{
      account: account,
      provider: provider
    } do
      now = DateTime.utc_now()

      assert Membership.Query.batch_upsert(account.id, provider.id, now, []) ==
               {:ok, %{upserted_memberships: 0}}

      assert Repo.aggregate(Membership, :count) == 0
    end

    test "creates new memberships", %{
      account: account,
      provider: provider,
      groups: groups,
      identities: identities
    } do
      now = DateTime.utc_now()

      # Define membership tuples (group_provider_identifier, user_provider_identifier)
      tuples = [
        {"group-001", "user-001"},
        {"group-001", "user-002"},
        {"group-002", "user-001"}
      ]

      assert {:ok, %{upserted_memberships: 3}} =
               Membership.Query.batch_upsert(account.id, provider.id, now, tuples)

      # Fetch the created memberships
      memberships =
        Membership.Query.all()
        |> Membership.Query.by_account_id(account.id)
        |> Repo.all()

      assert length(memberships) == 3

      # Verify all memberships were created with correct attributes
      for membership <- memberships do
        assert membership.account_id == account.id
        assert membership.last_synced_at == now
      end

      # Verify correct associations
      [identity1, identity2] = identities
      [group1, group2] = groups

      # Check user-001 is in both groups
      user1_memberships = Enum.filter(memberships, &(&1.actor_id == identity1.actor_id))
      assert length(user1_memberships) == 2

      assert MapSet.new(Enum.map(user1_memberships, & &1.group_id)) ==
               MapSet.new([group1.id, group2.id])

      # Check user-002 is only in group-001
      user2_memberships = Enum.filter(memberships, &(&1.actor_id == identity2.actor_id))
      assert length(user2_memberships) == 1
      assert hd(user2_memberships).group_id == group1.id
    end

    test "updates existing memberships", %{
      account: account,
      provider: provider,
      groups: groups,
      identities: identities
    } do
      now1 = DateTime.utc_now()
      now2 = DateTime.add(now1, 60, :second)
      [group1, _group2] = groups
      [identity1, identity2] = identities

      # Create initial membership
      existing_membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor_id: identity1.actor_id,
          group: group1,
          last_synced_at: now1
        )

      # Batch upsert with overlapping membership
      tuples = [
        # This should update existing
        {"group-001", "user-001"},
        # This should create new
        {"group-001", "user-002"}
      ]

      {:ok, %{upserted_memberships: 2}} =
        Membership.Query.batch_upsert(account.id, provider.id, now2, tuples)

      # Fetch the updated memberships
      memberships =
        Membership.Query.all()
        |> Membership.Query.by_account_id(account.id)
        |> Repo.all()

      assert length(memberships) == 2

      # Verify existing membership was updated
      updated_membership = Enum.find(memberships, &(&1.actor_id == identity1.actor_id))
      assert updated_membership.id == existing_membership.id
      assert updated_membership.last_synced_at == now2

      # Verify new membership was created
      new_membership = Enum.find(memberships, &(&1.actor_id == identity2.actor_id))
      assert new_membership.id != existing_membership.id
      assert new_membership.last_synced_at == now2
    end

    test "ignores invalid tuples (nonexistent groups or identities)", %{
      account: account,
      provider: provider
    } do
      now = DateTime.utc_now()

      # Include tuples with invalid identifiers
      tuples = [
        # Invalid group
        {"invalid-group", "user-001"},
        # Invalid identity
        {"group-001", "invalid-user"},
        # Both invalid
        {"invalid-group", "invalid-user"}
      ]

      # Should succeed but create 0 memberships since no valid tuples exist
      assert {:ok, %{upserted_memberships: 0}} =
               Membership.Query.batch_upsert(account.id, provider.id, now, tuples)

      # Verify no memberships were created
      memberships =
        Membership.Query.all()
        |> Membership.Query.by_account_id(account.id)
        |> Repo.all()

      assert memberships == []
    end

    test "creates only valid memberships when some tuples are invalid", %{
      account: account,
      provider: provider,
      groups: _groups,
      identities: _identities
    } do
      now = DateTime.utc_now()

      # Mix of valid and invalid tuples
      tuples = [
        # Valid
        {"group-001", "user-001"},
        # Invalid group
        {"invalid-group", "user-001"},
        # Invalid identity
        {"group-001", "invalid-user"},
        # Valid
        {"group-002", "user-002"}
      ]

      # Should create only the 2 valid memberships
      assert {:ok, %{upserted_memberships: 2}} =
               Membership.Query.batch_upsert(account.id, provider.id, now, tuples)

      memberships =
        Membership.Query.all()
        |> Membership.Query.by_account_id(account.id)
        |> Repo.all()

      assert length(memberships) == 2
    end

    test "handles memberships across different providers correctly", %{
      account: account,
      provider: provider,
      identities: identities
    } do
      # Create another provider and group
      {other_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      _other_group =
        Fixtures.Actors.create_group(
          account: account,
          provider: other_provider,
          provider_identifier: "other-group-001"
        )

      # Create identity for other provider
      _other_identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: other_provider,
          provider_identifier: "other-user-001",
          actor: [type: :account_user, account: account]
        )

      now = DateTime.utc_now()

      # Try to create memberships mixing providers (should be ignored)
      tuples = [
        # Valid for our provider
        {"group-001", "user-001"},
        # Group belongs to other provider (should be ignored)
        {"other-group-001", "user-001"},
        # Identity belongs to other provider (should be ignored)
        {"group-001", "other-user-001"}
      ]

      # Should only create 1 valid membership
      assert {:ok, %{upserted_memberships: 1}} =
               Membership.Query.batch_upsert(account.id, provider.id, now, tuples)

      memberships =
        Membership.Query.all()
        |> Membership.Query.by_account_id(account.id)
        |> Repo.all()

      assert length(memberships) == 1
      [membership] = memberships
      [identity1, _identity2] = identities
      assert membership.actor_id == identity1.actor_id
    end

    test "preserves memberships from different accounts", %{
      provider: provider,
      groups: _groups,
      identities: _identities
    } do
      other_account = Fixtures.Accounts.create_account()
      now = DateTime.utc_now()

      # Create membership for another account
      other_membership =
        Fixtures.Actors.create_membership(
          account: other_account,
          actor: Fixtures.Actors.create_actor(account: other_account),
          group: Fixtures.Actors.create_group(account: other_account)
        )

      # Batch upsert for our account
      tuples = [
        {"group-001", "user-001"}
      ]

      {:ok, %{upserted_memberships: 1}} =
        Membership.Query.batch_upsert(provider.account_id, provider.id, now, tuples)

      # Verify other account's membership is not affected
      assert Repo.get(Membership, other_membership.id)
      assert Repo.aggregate(Membership, :count) == 2
    end

    test "handles large batches efficiently", %{
      account: account,
      provider: provider
    } do
      now = DateTime.utc_now()

      # Create multiple groups and identities
      groups =
        for i <- 1..10 do
          Fixtures.Actors.create_group(
            account: account,
            provider: provider,
            provider_identifier: "large-batch-group-#{String.pad_leading("#{i}", 3, "0")}"
          )
        end

      identities =
        for i <- 1..50 do
          Fixtures.Auth.create_identity(
            account: account,
            provider: provider,
            provider_identifier: "large-batch-user-#{String.pad_leading("#{i}", 3, "0")}",
            actor: [type: :account_user, account: account]
          )
        end

      # Create many-to-many relationships (each user in each group)
      tuples =
        for group <- groups, identity <- identities do
          {group.provider_identifier, identity.provider_identifier}
        end

      expected_count = length(groups) * length(identities)

      assert {:ok, %{upserted_memberships: ^expected_count}} =
               Membership.Query.batch_upsert(account.id, provider.id, now, tuples)

      assert Repo.aggregate(Membership, :count) == expected_count
    end
  end
end
