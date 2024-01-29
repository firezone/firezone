defmodule Domain.ActorsTest do
  use Domain.DataCase, async: true
  import Domain.Actors
  alias Domain.Auth
  alias Domain.Actors

  describe "fetch_group_by_id/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_group_by_id("foo", subject) == {:error, :not_found}
    end

    test "does not return groups from other accounts", %{
      subject: subject
    } do
      group = Fixtures.Actors.create_group()
      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "returns deleted groups", %{
      account: account,
      subject: subject
    } do
      group =
        Fixtures.Actors.create_group(account: account)
        |> Fixtures.Actors.delete_group()

      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group by id", %{account: account, subject: subject} do
      group = Fixtures.Actors.create_group(account: account)
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Actors.create_group(account: account)
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns error when group does not exist", %{subject: subject} do
      assert fetch_group_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_group_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "list_groups/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns empty list when there are no groups", %{subject: subject} do
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list groups from other accounts", %{
      subject: subject
    } do
      Fixtures.Actors.create_group()
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list deleted groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Actors.create_group(account: account)
      |> Fixtures.Actors.delete_group()

      assert list_groups(subject) == {:ok, []}
    end

    test "returns all groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_group()

      assert {:ok, groups} = list_groups(subject)
      assert length(groups) == 2
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_groups(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "peek_group_actors/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns count of actors per group and first 3 actors", %{
      account: account,
      subject: subject
    } do
      group1 = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, group: group1)
      Fixtures.Actors.create_membership(account: account, group: group1)
      Fixtures.Actors.create_membership(account: account, group: group1)
      Fixtures.Actors.create_membership(account: account, group: group1)

      group2 = Fixtures.Actors.create_group(account: account)

      assert {:ok, peek} = peek_group_actors([group1, group2], 3, subject)

      assert length(Map.keys(peek)) == 2

      assert peek[group1.id].count == 4
      assert length(peek[group1.id].items) == 3
      assert [%Actors.Actor{} | _] = peek[group1.id].items

      assert peek[group2.id].count == 0
      assert Enum.empty?(peek[group2.id].items)
    end

    test "returns count of actors per group and first LIMIT actors", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, group: group)
      Fixtures.Actors.create_membership(account: account, group: group)

      other_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, group: other_group)

      assert {:ok, peek} = peek_group_actors([group], 1, subject)
      assert length(peek[group.id].items) == 1
    end

    test "ignores deleted actors", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Actors.create_group(account: account)
      actor = Fixtures.Actors.create_actor(account: account) |> Fixtures.Actors.delete()
      Fixtures.Actors.create_membership(account: account, group: group, actor: actor)
      Fixtures.Actors.create_membership(account: account, group: group)
      Fixtures.Actors.create_membership(account: account, group: group)
      Fixtures.Actors.create_membership(account: account, group: group)
      Fixtures.Actors.create_membership(account: account, group: group)

      assert {:ok, peek} = peek_group_actors([group], 3, subject)
      assert peek[group.id].count == 4
      assert length(peek[group.id].items) == 3
    end

    test "ignores other groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Actors.create_membership(account: account)
      Fixtures.Actors.create_membership(account: account)

      group = Fixtures.Actors.create_group(account: account)

      assert {:ok, peek} = peek_group_actors([group], 1, subject)
      assert peek[group.id].count == 0
      assert Enum.empty?(peek[group.id].items)
    end

    test "returns empty map on empty groups", %{subject: subject} do
      assert peek_group_actors([], 1, subject) == {:ok, %{}}
    end

    test "returns empty map on empty actors", %{account: account, subject: subject} do
      group = Fixtures.Actors.create_group(account: account)
      assert {:ok, peek} = peek_group_actors([group], 3, subject)
      assert length(Map.keys(peek)) == 1
      assert peek[group.id].count == 0
      assert Enum.empty?(peek[group.id].items)
    end

    test "does not allow peeking into other accounts", %{
      subject: subject
    } do
      other_account = Fixtures.Accounts.create_account()
      group = Fixtures.Actors.create_group(account: other_account)
      Fixtures.Actors.create_membership(account: other_account, group: group)

      assert {:ok, peek} = peek_group_actors([group], 3, subject)
      assert Map.has_key?(peek, group.id)
      assert peek[group.id].count == 0
      assert Enum.empty?(peek[group.id].items)
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert peek_group_actors([], 3, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "peek_actor_groups/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns count of actors per group and first 3 actors", %{
      account: account,
      subject: subject
    } do
      actor1 = Fixtures.Actors.create_actor(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor1)
      Fixtures.Actors.create_membership(account: account, actor: actor1)
      Fixtures.Actors.create_membership(account: account, actor: actor1)
      Fixtures.Actors.create_membership(account: account, actor: actor1)

      actor2 = Fixtures.Actors.create_actor(account: account)

      assert {:ok, peek} = peek_actor_groups([actor1, actor2], 3, subject)

      assert length(Map.keys(peek)) == 2

      assert peek[actor1.id].count == 4
      assert length(peek[actor1.id].items) == 3
      assert [%Actors.Group{} | _] = peek[actor1.id].items

      assert peek[actor2.id].count == 0
      assert Enum.empty?(peek[actor2.id].items)
    end

    test "returns count of actors per group and first LIMIT actors", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor)

      other_actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Actors.create_membership(account: account, actor: other_actor)

      assert {:ok, peek} = peek_actor_groups([actor], 1, subject)
      assert length(peek[actor.id].items) == 1
    end

    test "ignores deleted groups", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      group = Fixtures.Actors.create_group(account: account) |> Fixtures.Actors.delete()
      Fixtures.Actors.create_membership(account: account, group: group, actor: actor)
      Fixtures.Actors.create_membership(account: account, group: group)

      assert {:ok, peek} = peek_actor_groups([actor], 3, subject)
      assert peek[actor.id].count == 0
      assert Enum.empty?(peek[actor.id].items)
    end

    test "ignores other groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Actors.create_membership(account: account)
      Fixtures.Actors.create_membership(account: account)

      actor = Fixtures.Actors.create_actor(account: account)

      assert {:ok, peek} = peek_actor_groups([actor], 1, subject)
      assert peek[actor.id].count == 0
      assert Enum.empty?(peek[actor.id].items)
    end

    test "returns empty map on empty actors", %{subject: subject} do
      assert peek_actor_groups([], 1, subject) == {:ok, %{}}
    end

    test "returns empty map on empty groups", %{account: account, subject: subject} do
      actor = Fixtures.Actors.create_actor(account: account)
      assert {:ok, peek} = peek_actor_groups([actor], 3, subject)
      assert length(Map.keys(peek)) == 1
      assert peek[actor.id].count == 0
      assert Enum.empty?(peek[actor.id].items)
    end

    test "does not allow peeking into other accounts", %{
      subject: subject
    } do
      other_account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: other_account)
      Fixtures.Actors.create_membership(account: other_account, actor: actor)

      assert {:ok, peek} = peek_actor_groups([actor], 3, subject)
      assert Map.has_key?(peek, actor.id)
      assert peek[actor.id].count == 0
      assert Enum.empty?(peek[actor.id].items)
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert peek_actor_groups([], 3, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "sync_provider_groups_multi/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      %{account: account, provider: provider, bypass: bypass}
    end

    test "creates new groups", %{provider: provider} do
      attrs_list = [
        %{"name" => "Group:Infrastructure", "provider_identifier" => "G:GROUP_ID1"},
        %{"name" => "OrgUnit:Engineering", "provider_identifier" => "OU:OU_ID1"}
      ]

      multi = sync_provider_groups_multi(provider, attrs_list)

      assert {:ok,
              %{
                plan_groups: {upsert, []},
                delete_groups: {0, nil},
                upsert_groups: [_group1, _group2],
                group_ids_by_provider_identifier: group_ids_by_provider_identifier
              }} = Repo.transaction(multi)

      assert Enum.all?(["G:GROUP_ID1", "OU:OU_ID1"], &(&1 in upsert))
      groups = Repo.all(Actors.Group)
      group_names = Enum.map(attrs_list, & &1["name"])
      assert length(groups) == 2

      for group <- groups do
        assert group.inserted_at
        assert group.updated_at

        assert group.created_by == :provider
        assert group.provider_id == provider.id

        assert group.name in group_names

        assert Map.get(group_ids_by_provider_identifier, group.provider_identifier) == group.id
      end

      assert Enum.count(group_ids_by_provider_identifier) == 2
    end

    test "updates existing groups", %{account: account, provider: provider} do
      group1 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:GROUP_ID1"
        )

      _group2 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "OU:OU_ID1"
        )

      attrs_list = [
        %{"name" => "Group:Infrastructure", "provider_identifier" => "G:GROUP_ID1"},
        %{"name" => "OrgUnit:Engineering", "provider_identifier" => "OU:OU_ID1"}
      ]

      multi = sync_provider_groups_multi(provider, attrs_list)

      assert {:ok,
              %{
                plan_groups: {upsert, []},
                delete_groups: {0, nil},
                upsert_groups: [_group1, _group2],
                group_ids_by_provider_identifier: group_ids_by_provider_identifier
              }} = Repo.transaction(multi)

      assert Enum.all?(["G:GROUP_ID1", "OU:OU_ID1"], &(&1 in upsert))
      assert Repo.aggregate(Actors.Group, :count) == 2

      groups = Repo.all(Actors.Group)
      group_names = Enum.map(attrs_list, & &1["name"])
      assert length(groups) == 2

      for group <- groups do
        assert group.name in group_names
        assert group.inserted_at
        assert group.updated_at
        assert group.provider_id == provider.id
        assert group.created_by == group1.created_by
        assert Map.get(group_ids_by_provider_identifier, group.provider_identifier) == group.id
      end

      assert Enum.count(group_ids_by_provider_identifier) == 2
    end

    test "deletes removed groups", %{account: account, provider: provider} do
      Fixtures.Actors.create_group(
        account: account,
        provider: provider,
        provider_identifier: "G:GROUP_ID1"
      )

      Fixtures.Actors.create_group(
        account: account,
        provider: provider,
        provider_identifier: "OU:OU_ID1"
      )

      attrs_list = []

      multi = sync_provider_groups_multi(provider, attrs_list)

      assert {:ok,
              %{
                groups: [_group1, _group2],
                plan_groups: {[], delete},
                delete_groups: {2, nil},
                upsert_groups: [],
                group_ids_by_provider_identifier: group_ids_by_provider_identifier
              }} = Repo.transaction(multi)

      assert Enum.all?(["G:GROUP_ID1", "OU:OU_ID1"], &(&1 in delete))
      assert Repo.aggregate(Actors.Group, :count) == 2
      assert Repo.aggregate(Actors.Group.Query.not_deleted(), :count) == 0

      assert Enum.empty?(group_ids_by_provider_identifier)
    end

    test "ignores groups that are not synced from the provider", %{
      account: account,
      provider: provider
    } do
      {other_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      Fixtures.Actors.create_group(
        account: account,
        provider: other_provider,
        provider_identifier: "G:GROUP_ID1"
      )

      Fixtures.Actors.create_group(
        account: account,
        provider_identifier: "OU:OU_ID1"
      )

      attrs_list = []

      multi = sync_provider_groups_multi(provider, attrs_list)

      assert Repo.transaction(multi) ==
               {:ok,
                %{
                  groups: [],
                  plan_groups: {[], []},
                  delete_groups: {0, nil},
                  upsert_groups: [],
                  group_ids_by_provider_identifier: %{}
                }}
    end
  end

  describe "sync_provider_memberships_multi/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      group1 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:GROUP_ID1"
        )

      group2 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "OU:OU_ID1"
        )

      identity1 =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "USER_ID1"
        )

      identity2 =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "USER_ID2"
        )

      %{
        account: account,
        provider: provider,
        group1: group1,
        group2: group2,
        identity1: identity1,
        identity2: identity2,
        bypass: bypass
      }
    end

    test "creates new memberships", %{
      provider: provider,
      group1: group1,
      group2: group2,
      identity1: identity1,
      identity2: identity2
    } do
      tuples_list = [
        {group1.provider_identifier, identity1.provider_identifier},
        {group2.provider_identifier, identity2.provider_identifier}
      ]

      actor_ids_by_provider_identifier = %{
        identity1.provider_identifier => identity1.actor_id,
        identity2.provider_identifier => identity2.actor_id
      }

      group_ids_by_provider_identifier = %{
        group1.provider_identifier => group1.id,
        group2.provider_identifier => group2.id
      }

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.put(:actor_ids_by_provider_identifier, actor_ids_by_provider_identifier)
        |> Ecto.Multi.put(:group_ids_by_provider_identifier, group_ids_by_provider_identifier)
        |> sync_provider_memberships_multi(provider, tuples_list)

      assert {:ok,
              %{
                plan_memberships: {insert, []},
                delete_memberships: {0, nil},
                upsert_memberships: [_membership1, _membership2]
              }} = Repo.transaction(multi)

      assert {group1.id, identity1.actor_id} in insert
      assert {group2.id, identity2.actor_id} in insert

      memberships = Repo.all(Actors.Membership)
      assert length(memberships) == 2

      for membership <- memberships do
        assert {membership.group_id, membership.actor_id} in insert
      end
    end

    test "updates existing memberships", %{
      account: account,
      provider: provider,
      group1: group1,
      group2: group2,
      identity1: identity1,
      identity2: identity2
    } do
      Fixtures.Actors.create_membership(
        account: account,
        group: group1,
        actor_id: identity1.actor_id
      )

      Fixtures.Actors.create_membership(
        account: account,
        group: group2,
        actor_id: identity2.actor_id
      )

      tuples_list = [
        {group1.provider_identifier, identity1.provider_identifier},
        {group2.provider_identifier, identity2.provider_identifier}
      ]

      actor_ids_by_provider_identifier = %{
        identity1.provider_identifier => identity1.actor_id,
        identity2.provider_identifier => identity2.actor_id
      }

      group_ids_by_provider_identifier = %{
        group1.provider_identifier => group1.id,
        group2.provider_identifier => group2.id
      }

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.put(:actor_ids_by_provider_identifier, actor_ids_by_provider_identifier)
        |> Ecto.Multi.put(:group_ids_by_provider_identifier, group_ids_by_provider_identifier)
        |> sync_provider_memberships_multi(provider, tuples_list)

      assert {:ok,
              %{
                plan_memberships: {upsert, []},
                delete_memberships: {0, nil},
                upsert_memberships: [membership1, membership2]
              }} = Repo.transaction(multi)

      assert length(upsert) == 2
      assert {group1.id, identity1.actor_id} in upsert
      assert {group2.id, identity2.actor_id} in upsert
      assert {membership1.group_id, membership1.actor_id} in upsert
      assert {membership2.group_id, membership2.actor_id} in upsert

      assert Repo.aggregate(Actors.Membership, :count) == 2
      assert Repo.aggregate(Actors.Membership.Query.all(), :count) == 2
    end

    test "deletes removed memberships", %{
      account: account,
      provider: provider,
      group1: group1,
      group2: group2,
      identity1: identity1,
      identity2: identity2
    } do
      Fixtures.Actors.create_membership(
        account: account,
        group: group1,
        actor_id: identity1.actor_id
      )

      Fixtures.Actors.create_membership(
        account: account,
        group: group2,
        actor_id: identity2.actor_id
      )

      tuples_list = []

      actor_ids_by_provider_identifier = %{
        identity1.provider_identifier => identity1.actor_id,
        identity2.provider_identifier => identity2.actor_id
      }

      group_ids_by_provider_identifier = %{
        group1.provider_identifier => group1.id,
        group2.provider_identifier => group2.id
      }

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.put(:actor_ids_by_provider_identifier, actor_ids_by_provider_identifier)
        |> Ecto.Multi.put(:group_ids_by_provider_identifier, group_ids_by_provider_identifier)
        |> sync_provider_memberships_multi(provider, tuples_list)

      assert {:ok,
              %{
                plan_memberships: {[], delete},
                delete_memberships: {2, nil},
                upsert_memberships: []
              }} = Repo.transaction(multi)

      assert {group1.id, identity1.actor_id} in delete
      assert {group2.id, identity2.actor_id} in delete

      assert Repo.aggregate(Actors.Membership, :count) == 0
      assert Repo.aggregate(Actors.Membership.Query.all(), :count) == 0
    end

    test "deletes memberships of removed groups", %{
      account: account,
      provider: provider,
      group1: group1,
      group2: group2,
      identity1: identity1,
      identity2: identity2
    } do
      Fixtures.Actors.create_membership(
        account: account,
        group: group1,
        actor_id: identity1.actor_id
      )

      Fixtures.Actors.create_membership(
        account: account,
        group: group2,
        actor_id: identity2.actor_id
      )

      tuples_list = [
        {group1.provider_identifier, identity1.provider_identifier}
      ]

      actor_ids_by_provider_identifier = %{
        identity1.provider_identifier => identity1.actor_id,
        identity2.provider_identifier => identity2.actor_id
      }

      group_ids_by_provider_identifier = %{
        group1.provider_identifier => group1.id
      }

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.put(:actor_ids_by_provider_identifier, actor_ids_by_provider_identifier)
        |> Ecto.Multi.put(:group_ids_by_provider_identifier, group_ids_by_provider_identifier)
        |> sync_provider_memberships_multi(provider, tuples_list)

      assert {:ok,
              %{
                plan_memberships: {upsert, delete},
                delete_memberships: {1, nil},
                upsert_memberships: [_membership]
              }} = Repo.transaction(multi)

      assert upsert == [{group1.id, identity1.actor_id}]
      assert delete == [{group2.id, identity2.actor_id}]

      assert Repo.aggregate(Actors.Membership, :count) == 1
      assert Repo.aggregate(Actors.Membership.Query.all(), :count) == 1
    end

    test "ignores memberships that are not synced from the provider", %{
      account: account,
      provider: provider,
      group1: group1,
      group2: group2,
      identity1: identity1,
      identity2: identity2
    } do
      Fixtures.Actors.create_membership(account: account)

      tuples_list = []

      actor_ids_by_provider_identifier = %{
        identity1.provider_identifier => identity1.actor_id,
        identity2.provider_identifier => identity2.actor_id
      }

      group_ids_by_provider_identifier = %{
        group1.provider_identifier => group1.id,
        group2.provider_identifier => group2.id
      }

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.put(:actor_ids_by_provider_identifier, actor_ids_by_provider_identifier)
        |> Ecto.Multi.put(:group_ids_by_provider_identifier, group_ids_by_provider_identifier)
        |> sync_provider_memberships_multi(provider, tuples_list)

      assert {:ok,
              %{
                plan_memberships: {[], []},
                delete_memberships: {0, nil},
                upsert_memberships: []
              }} = Repo.transaction(multi)
    end
  end

  describe "new_group/0" do
    test "returns group changeset" do
      assert %Ecto.Changeset{data: %Actors.Group{}, changes: changes} = new_group()
      assert Enum.empty?(changes)
    end
  end

  describe "group_synced?/1" do
    test "returns true for synced groups" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)
      assert group_synced?(group)
    end

    test "returns false for manually created groups" do
      group = Fixtures.Actors.create_group()
      assert group_synced?(group) == false
    end
  end

  describe "create_group/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns error on empty attrs", %{subject: subject} do
      assert {:error, changeset} = create_group(%{}, subject)
      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      attrs = %{name: String.duplicate("A", 65)}
      assert {:error, changeset} = create_group(attrs, subject)
      assert errors_on(changeset) == %{name: ["should be at most 64 character(s)"]}

      Fixtures.Actors.create_group(account: account, name: "foo")
      attrs = %{name: "foo", tokens: [%{}]}
      assert {:error, changeset} = create_group(attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "creates a group", %{subject: subject} do
      attrs = Fixtures.Actors.group_attrs()

      assert {:ok, group} = create_group(attrs, subject)
      assert group.id
      assert group.name == attrs.name

      group = Repo.preload(group, :memberships)
      assert group.memberships == []
    end

    test "creates a group with memberships", %{account: account, actor: actor, subject: subject} do
      attrs =
        Fixtures.Actors.group_attrs(
          memberships: [
            %{actor_id: actor.id}
          ]
        )

      :ok = subscribe_for_membership_updates_for_actor(actor)

      assert {:ok, group} = create_group(attrs, subject)
      assert group.id
      assert group.name == attrs.name

      group = Repo.preload(group, :memberships)
      assert [%Actors.Membership{} = membership] = group.memberships
      assert membership.actor_id == actor.id
      assert membership.account_id == account.id
      assert membership.group_id == group.id

      assert_receive {:create_membership, actor_id, group_id}
      assert actor_id == actor.id
      assert group_id == group.id
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_group(%{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "change_group/1" do
    test "returns changeset with given changes" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      group = Fixtures.Actors.create_group(account: account) |> Repo.preload(:memberships)

      group_attrs =
        Fixtures.Actors.group_attrs(
          memberships: [
            %{actor_id: actor.id}
          ]
        )

      assert changeset = change_group(group, group_attrs)
      assert changeset.valid?

      assert %{name: name, memberships: [membership]} = changeset.changes
      assert name == group_attrs.name
      assert membership.changes.account_id == account.id
      assert membership.changes.actor_id == actor.id
    end

    test "raises if group is synced" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)

      assert_raise ArgumentError, "can't change synced groups", fn ->
        change_group(group, %{})
      end
    end
  end

  describe "update_group/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "does not allow to reset required fields to empty values", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Actors.create_group(account: account)
      attrs = %{name: nil}

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      group = Fixtures.Actors.create_group(account: account)

      attrs = %{name: String.duplicate("A", 65)}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert errors_on(changeset) == %{name: ["should be at most 64 character(s)"]}

      Fixtures.Actors.create_group(account: account, name: "foo")
      attrs = %{name: "foo"}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "updates a group", %{account: account, subject: subject} do
      group = Fixtures.Actors.create_group(account: account)

      attrs = Fixtures.Actors.group_attrs()
      assert {:ok, group} = update_group(group, attrs, subject)
      assert group.name == attrs.name
    end

    test "updates group memberships and triggers policy access events", %{
      account: account,
      actor: actor1,
      subject: subject
    } do
      group = Fixtures.Actors.create_group(account: account, memberships: [])
      actor2 = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      resource = Fixtures.Resources.create_resource(account: account)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: group,
          resource: resource
        )

      resource_id = resource.id
      policy_id = policy.id
      group_id = group.id
      actor1_id = actor1.id
      actor2_id = actor2.id
      :ok = subscribe_for_membership_updates_for_actor(actor1)
      :ok = subscribe_for_membership_updates_for_actor(actor2)
      :ok = Domain.Policies.subscribe_for_events_for_actor(actor1)
      :ok = Domain.Policies.subscribe_for_events_for_actor(actor2)

      attrs = %{memberships: []}
      assert {:ok, %{memberships: []}} = update_group(group, attrs, subject)

      # Add a membership
      attrs = %{memberships: [%{actor_id: actor1.id}]}
      assert {:ok, %{memberships: [membership]}} = update_group(group, attrs, subject)
      assert membership.actor_id == actor1.id
      assert Repo.one(Actors.Membership).actor_id == membership.actor_id

      assert_receive {:create_membership, ^actor1_id, ^group_id}
      assert_receive {:allow_access, ^policy_id, ^group_id, ^resource_id}

      # Delete existing membership and create a new one
      attrs = %{memberships: [%{actor_id: actor2.id}]}
      assert {:ok, %{memberships: [membership]}} = update_group(group, attrs, subject)
      assert membership.actor_id == actor2.id
      assert Repo.one(Actors.Membership).actor_id == membership.actor_id

      assert_receive {:delete_membership, ^actor1_id, ^group_id}
      assert_receive {:reject_access, ^policy_id, ^group_id, ^resource_id}
      assert_receive {:create_membership, ^actor2_id, ^group_id}
      assert_receive {:allow_access, ^policy_id, ^group_id, ^resource_id}

      # Doesn't produce changes when membership is not changed
      attrs = %{memberships: [Map.from_struct(membership)]}
      assert {:ok, %{memberships: [membership]}} = update_group(group, attrs, subject)
      assert membership.actor_id == actor2.id
      assert Repo.one(Actors.Membership).actor_id == membership.actor_id

      refute_received {:create_membership, _, _}
      refute_received {:allow_access, _, _, _}
      refute_received {:reject_access, _, _, _}

      # Add one more membership
      attrs = %{memberships: [%{actor_id: actor1.id}, %{actor_id: actor2.id}]}
      assert {:ok, %{memberships: memberships}} = update_group(group, attrs, subject)
      assert [membership1, membership2] = memberships
      assert membership1.actor_id == actor1.id
      assert membership2.actor_id == actor2.id
      assert Repo.aggregate(Actors.Membership, :count, :actor_id) == 2

      assert_receive {:create_membership, ^actor1_id, ^group_id}
      assert_receive {:allow_access, ^policy_id, ^group_id, ^resource_id}

      # Delete all memberships
      assert {:ok, %{memberships: []}} = update_group(group, %{memberships: []}, subject)
      assert Repo.aggregate(Actors.Membership, :count, :actor_id) == 0

      assert_receive {:delete_membership, ^actor1_id, ^group_id}
      assert_receive {:delete_membership, ^actor2_id, ^group_id}
      assert_receive {:reject_access, ^policy_id, ^group_id, ^resource_id}
      assert_receive {:reject_access, ^policy_id, ^group_id, ^resource_id}
    end

    test "returns error when subject has no permission to manage groups", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Actors.create_group(account: account)

      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_group(group, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end

    test "raises if group is synced", %{
      account: account,
      subject: subject
    } do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)

      assert update_group(group, %{}, subject) == {:error, :synced_group}
    end
  end

  describe "delete_group/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns error on state conflict", %{account: account, subject: subject} do
      group = Fixtures.Actors.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert delete_group(deleted, subject) == {:error, :not_found}
      assert delete_group(group, subject) == {:error, :not_found}
    end

    test "deletes groups", %{account: account, subject: subject} do
      group = Fixtures.Actors.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at
    end

    test "deletes group memberships", %{account: account, subject: subject} do
      group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, group: group)

      assert {:ok, _deleted} = delete_group(group, subject)

      assert Repo.aggregate(Actors.Membership, :count) == 0
    end

    test "deletes policies that use this group", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Actors.create_group(account: account)

      policy = Fixtures.Policies.create_policy(account: account, actor_group: group)
      other_policy = Fixtures.Policies.create_policy(account: account)

      assert {:ok, _resource} = delete_group(group, subject)

      refute is_nil(Repo.get_by(Domain.Policies.Policy, id: policy.id).deleted_at)
      assert is_nil(Repo.get_by(Domain.Policies.Policy, id: other_policy.id).deleted_at)
    end

    test "returns error when subject has no permission to delete groups", %{
      subject: subject
    } do
      group = Fixtures.Actors.create_group()

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_group(group, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end

    test "raises if group is synced", %{
      account: account,
      subject: subject
    } do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)

      assert delete_group(group, subject) == {:error, :synced_group}
    end
  end

  describe "delete_groups_for/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        provider: provider,
        identity: identity,
        subject: subject
      }
    end

    test "does nothing on state conflict", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      Fixtures.Actors.create_group(account: account, provider: provider)

      assert {:ok, [_deleted]} = delete_groups_for(provider, subject)
      assert delete_groups_for(provider, subject) == {:ok, []}
      assert delete_groups_for(provider, subject) == {:ok, []}
    end

    test "deletes provider groups", %{account: account, provider: provider, subject: subject} do
      group = Fixtures.Actors.create_group(account: account, provider: provider)

      assert {:ok, [deleted]} = delete_groups_for(provider, subject)
      assert deleted.deleted_at

      refute is_nil(Repo.get(Actors.Group, group.id).deleted_at)
    end

    test "deletes provider group memberships", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group)

      :ok = subscribe_for_membership_updates_for_actor(actor)

      assert {:ok, _deleted} = delete_groups_for(provider, subject)

      refute Repo.get_by(Actors.Membership, group_id: group.id)

      assert_receive {:delete_membership, actor_id, group_id}
      assert actor_id == actor.id
      assert group_id == group.id
    end

    test "deletes policies that use deleted groups", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      group = Fixtures.Actors.create_group(account: account, provider: provider)

      policy = Fixtures.Policies.create_policy(account: account, actor_group: group)
      other_policy = Fixtures.Policies.create_policy(account: account)

      assert {:ok, _resource} = delete_groups_for(provider, subject)

      refute is_nil(Repo.get_by(Domain.Policies.Policy, id: policy.id).deleted_at)
      assert is_nil(Repo.get_by(Domain.Policies.Policy, id: other_policy.id).deleted_at)
    end

    test "returns error when subject has no permission to delete groups", %{
      provider: provider,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_groups_for(provider, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "fetch_actors_count_by_type/0" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        subject: subject
      }
    end

    test "returns correct count of not deleted actors by type", %{
      account: account,
      subject: subject
    } do
      assert fetch_actors_count_by_type(:account_admin_user, subject) == 1
      assert fetch_actors_count_by_type(:account_user, subject) == 0

      Fixtures.Actors.create_actor(type: :account_admin_user)
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      assert {:ok, _actor} = delete_actor(actor, subject)
      assert fetch_actors_count_by_type(:account_admin_user, subject) == 1
      assert fetch_actors_count_by_type(:account_user, subject) == 0

      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      assert fetch_actors_count_by_type(:account_admin_user, subject) == 2
      assert fetch_actors_count_by_type(:account_user, subject) == 0

      Fixtures.Actors.create_actor(type: :account_user)
      Fixtures.Actors.create_actor(type: :account_user, account: account)
      assert fetch_actors_count_by_type(:account_admin_user, subject) == 2
      assert fetch_actors_count_by_type(:account_user, subject) == 1

      for _ <- 1..5, do: Fixtures.Actors.create_actor(type: :account_user, account: account)
      assert fetch_actors_count_by_type(:account_admin_user, subject) == 2
      assert fetch_actors_count_by_type(:account_user, subject) == 6
    end

    test "returns error when subject can not view actors", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_actors_count_by_type(:foo, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "fetch_groups_count_grouped_by_provider_id/1" do
    test "returns empty map when there are no groups" do
      subject = Fixtures.Auth.create_subject()
      assert fetch_groups_count_grouped_by_provider_id(subject) == {:ok, %{}}
    end

    test "returns count of actor groups by provider id" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {google_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account, name: "google")

      {vault_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account, name: "vault")

      Fixtures.Actors.create_group(
        account: account,
        subject: subject
      )

      Fixtures.Actors.create_group(
        account: account,
        subject: subject,
        provider: google_provider,
        provider_identifier: Ecto.UUID.generate()
      )

      Fixtures.Actors.create_group(
        account: account,
        subject: subject,
        provider: vault_provider,
        provider_identifier: Ecto.UUID.generate()
      )

      Fixtures.Actors.create_group(
        account: account,
        subject: subject,
        provider: vault_provider,
        provider_identifier: Ecto.UUID.generate()
      )

      assert fetch_groups_count_grouped_by_provider_id(subject) ==
               {:ok,
                %{
                  google_provider.id => 1,
                  vault_provider.id => 2
                }}
    end
  end

  describe "fetch_actor_by_id/2" do
    test "returns error when actor is not found" do
      subject = Fixtures.Auth.create_subject()
      assert fetch_actor_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUID" do
      subject = Fixtures.Auth.create_subject()
      assert fetch_actor_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns own actor" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert {:ok, returned_actor} = fetch_actor_by_id(actor.id, subject)
      assert returned_actor.id == actor.id
    end

    test "returns non own actor" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      actor = Fixtures.Actors.create_actor(account: account)

      assert {:ok, returned_actor} = fetch_actor_by_id(actor.id, subject)
      assert returned_actor.id == actor.id
    end

    test "returns error when actor is in another account" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      actor = Fixtures.Actors.create_actor()

      assert fetch_actor_by_id(actor.id, subject) == {:error, :not_found}
    end

    test "returns error when subject can not view actors" do
      subject = Fixtures.Auth.create_subject()
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_actor_by_id("foo", subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end

    test "associations are preloaded when opts given" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, actor} = fetch_actor_by_id(actor.id, subject, preload: :identities)

      assert Ecto.assoc_loaded?(actor.identities)
    end
  end

  describe "fetch_actor_by_id/1" do
    test "returns error when actor is not found" do
      assert fetch_actor_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUIDv4" do
      assert fetch_actor_by_id("foo") == {:error, :not_found}
    end

    test "returns actor" do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user)
      assert {:ok, returned_actor} = fetch_actor_by_id(actor.id)
      assert returned_actor.id == actor.id
    end
  end

  describe "fetch_actor_by_id!/1" do
    test "raises when actor is not found" do
      assert_raise(Ecto.NoResultsError, fn ->
        fetch_actor_by_id!(Ecto.UUID.generate())
      end)
    end

    test "raises when id is not a valid UUIDv4" do
      assert_raise(Ecto.Query.CastError, fn ->
        assert fetch_actor_by_id!("foo")
      end)
    end

    test "returns actor" do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user)
      assert returned_actor = fetch_actor_by_id!(actor.id)
      assert returned_actor.id == actor.id
    end
  end

  describe "list_actors/2" do
    test "returns empty list when there are not actors" do
      subject =
        %Auth.Subject{
          identity: nil,
          actor: %{id: Ecto.UUID.generate()},
          account: %{id: Ecto.UUID.generate()},
          token_id: nil,
          context: nil,
          expires_at: nil,
          permissions: MapSet.new()
        }
        |> Fixtures.Auth.set_permissions([
          Actors.Authorizer.manage_actors_permission()
        ])

      assert list_actors(subject) == {:ok, []}
    end

    test "returns list of actors in all types" do
      account = Fixtures.Accounts.create_account()
      actor1 = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      actor2 = Fixtures.Actors.create_actor(account: account, type: :account_user)
      Fixtures.Actors.create_actor(type: :account_user)

      identity1 = Fixtures.Auth.create_identity(account: account, actor: actor1)
      subject = Fixtures.Auth.create_subject(identity: identity1)

      assert {:ok, actors} = list_actors(subject)
      assert length(actors) == 2
      assert Enum.sort(Enum.map(actors, & &1.id)) == Enum.sort([actor1.id, actor2.id])
    end

    test "returns error when subject can not view actors" do
      subject = Fixtures.Auth.create_subject()
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_actors(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end

    test "associations are preloaded when opts given" do
      account = Fixtures.Accounts.create_account()

      actor1 = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity1 = Fixtures.Auth.create_identity(account: account, actor: actor1)
      subject = Fixtures.Auth.create_subject(identity: identity1)

      actor2 = Fixtures.Actors.create_actor(type: :account_user, account: account)
      Fixtures.Auth.create_identity(account: account, actor: actor2)

      {:ok, actors} = list_actors(subject, preload: :identities)
      assert length(actors) == 2

      assert Enum.all?(actors, fn a -> Ecto.assoc_loaded?(a.identities) end)
    end
  end

  describe "create_actor/4" do
    setup do
      account = Fixtures.Accounts.create_account()

      %{
        account: account
      }
    end

    test "returns changeset error when required attrs are missing", %{
      account: account
    } do
      assert {:error, changeset} = create_actor(account, %{})
      refute changeset.valid?

      assert errors_on(changeset) == %{
               type: ["can't be blank"],
               name: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{
      account: account
    } do
      attrs = Fixtures.Actors.actor_attrs(type: :foo)

      assert {:error, changeset} = create_actor(account, attrs)
      refute changeset.valid?

      assert errors_on(changeset) == %{
               type: ["is invalid"]
             }
    end

    test "creates an actor in given type", %{
      account: account
    } do
      for type <- [:account_user, :account_admin_user, :service_account] do
        attrs = Fixtures.Actors.actor_attrs(type: type)
        assert {:ok, actor} = create_actor(account, attrs)
        assert actor.type == type
      end
    end

    test "creates an actor", %{
      account: account
    } do
      attrs = Fixtures.Actors.actor_attrs()

      assert {:ok, actor} = create_actor(account, attrs)

      assert actor.type == attrs.type
      assert actor.type == attrs.type
      assert is_nil(actor.disabled_at)
      assert is_nil(actor.deleted_at)
    end
  end

  describe "create_actor/5" do
    setup do
      account = Fixtures.Accounts.create_account()

      %{
        account: account
      }
    end

    test "returns error when subject can not create actors", %{
      account: account
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      subject =
        Fixtures.Auth.create_subject(account: account, actor: actor)
        |> Fixtures.Auth.remove_permissions()

      attrs = %{}

      assert create_actor(account, attrs, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end

    test "returns error when subject tries to create an account in another account", %{
      account: account
    } do
      subject = Fixtures.Auth.create_subject()
      attrs = %{}
      assert create_actor(account, attrs, subject) == {:error, :unauthorized}
    end

    test "returns error when subject is trying to create an actor with a privilege escalation", %{
      account: account
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      subject = Fixtures.Auth.create_subject(account: account, actor: actor)

      required_permissions = [Actors.Authorizer.manage_actors_permission()]

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.set_permissions(required_permissions)

      attrs = %{
        type: :account_admin_user,
        name: "John Smith"
      }

      assert {:error, changeset} = create_actor(account, attrs, subject)

      assert "does not have permissions to grant this actor type" in errors_on(changeset).type
    end
  end

  describe "update_actor/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        subject: subject
      }
    end

    test "allows changing name of an actor", %{account: account, subject: subject} do
      actor = Fixtures.Actors.create_actor(name: "ABC", account: account)
      assert {:ok, %{name: "DEF"}} = update_actor(actor, %{name: "DEF"}, subject)
      assert {:ok, %{name: "ABC"}} = update_actor(actor, %{name: "ABC"}, subject)
    end

    test "does not allow changing name of a synced actor", %{account: account, subject: subject} do
      actor =
        Fixtures.Actors.create_actor(name: "ABC", account: account)
        |> Fixtures.Actors.update(last_synced_at: DateTime.utc_now())

      assert {:ok, %{name: "ABC"}} = update_actor(actor, %{name: "DEF"}, subject)
    end

    test "allows admin to change other actors type", %{account: account, subject: subject} do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      assert {:ok, %{type: :account_user}} = update_actor(actor, %{type: :account_user}, subject)

      assert {:ok, %{type: :account_admin_user}} =
               update_actor(actor, %{type: :account_admin_user}, subject)

      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      assert {:ok, %{type: :account_user}} = update_actor(actor, %{type: :account_user}, subject)

      assert {:ok, %{type: :account_admin_user}} =
               update_actor(actor, %{type: :account_admin_user}, subject)
    end

    test "allows admin to change synced actors type", %{account: account, subject: subject} do
      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
        |> Fixtures.Actors.update(last_synced_at: DateTime.utc_now())

      assert {:ok, %{type: :account_user}} = update_actor(actor, %{type: :account_user}, subject)

      actor =
        Fixtures.Actors.create_actor(type: :account_user, account: account)
        |> Fixtures.Actors.update(last_synced_at: DateTime.utc_now())

      assert {:ok, %{type: :account_admin_user}} =
               update_actor(actor, %{type: :account_admin_user}, subject)
    end

    test "returns error when subject can not manage types", %{account: account} do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      subject =
        Fixtures.Auth.create_subject(account: account, actor: actor)
        |> Fixtures.Auth.remove_permissions()

      assert update_actor(actor, %{type: :foo}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end

    test "allows changing not synced memberships and triggers policy access events", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      group1 = Fixtures.Actors.create_group(account: account)
      group2 = Fixtures.Actors.create_group(account: account)

      resource = Fixtures.Resources.create_resource(account: account)

      policy1 =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: group1,
          resource: resource
        )

      policy2 =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: group2,
          resource: resource
        )

      resource_id = resource.id
      policy1_id = policy1.id
      policy2_id = policy2.id
      actor_id = actor.id
      group1_id = group1.id
      group2_id = group2.id
      :ok = subscribe_for_membership_updates_for_actor(actor)
      :ok = Domain.Policies.subscribe_for_events_for_actor(actor)

      attrs = %{memberships: []}
      assert {:ok, %{memberships: []}} = update_actor(actor, attrs, subject)

      # Add a membership
      attrs = %{memberships: [%{group_id: group1.id}]}
      assert {:ok, %{memberships: [membership]}} = update_actor(actor, attrs, subject)
      assert membership.group_id == group1.id
      assert Repo.one(Actors.Membership).group_id == membership.group_id

      assert_receive {:create_membership, ^actor_id, ^group1_id}
      assert_receive {:allow_access, ^policy1_id, ^group1_id, ^resource_id}

      # Delete existing membership and create a new one
      attrs = %{memberships: [%{group_id: group2.id}]}
      assert {:ok, %{memberships: [membership]}} = update_actor(actor, attrs, subject)
      assert membership.group_id == group2.id
      assert Repo.one(Actors.Membership).group_id == membership.group_id

      assert_receive {:delete_membership, ^actor_id, ^group1_id}
      assert_receive {:reject_access, ^policy1_id, ^group1_id, ^resource_id}
      assert_receive {:create_membership, ^actor_id, ^group2_id}
      assert_receive {:allow_access, ^policy2_id, ^group2_id, ^resource_id}

      # Doesn't produce changes when membership is not changed
      attrs = %{memberships: [Map.from_struct(membership)]}
      assert {:ok, %{memberships: [membership]}} = update_actor(actor, attrs, subject)
      assert membership.group_id == group2.id
      assert Repo.one(Actors.Membership).group_id == membership.group_id

      refute_received {:create_membership, _, _}
      refute_received {:allow_access, _, _, _}
      refute_received {:reject_access, _, _, _}

      # Add one more membership
      attrs = %{memberships: [%{group_id: group1.id}, %{group_id: group2.id}]}
      assert {:ok, %{memberships: memberships}} = update_actor(actor, attrs, subject)
      assert [membership1, membership2] = memberships
      assert membership1.group_id == group1.id
      assert membership2.group_id == group2.id
      assert Repo.aggregate(Actors.Membership, :count, :group_id) == 2

      assert_receive {:create_membership, ^actor_id, ^group1_id}
      assert_receive {:allow_access, ^policy1_id, ^group1_id, ^resource_id}

      # Delete all memberships
      assert {:ok, %{memberships: []}} = update_actor(actor, %{memberships: []}, subject)
      assert Repo.aggregate(Actors.Membership, :count, :group_id) == 0

      assert_receive {:delete_membership, ^actor_id, ^group1_id}
      assert_receive {:reject_access, ^policy1_id, ^group1_id, ^resource_id}
      assert_receive {:delete_membership, ^actor_id, ^group2_id}
      assert_receive {:reject_access, ^policy2_id, ^group2_id, ^resource_id}
    end

    test "returns error on invalid membership", %{account: account, subject: subject} do
      actor = Fixtures.Actors.create_actor(account: account)

      attrs = %{memberships: [%{}]}
      assert {:error, changeset} = update_actor(actor, attrs, subject)
      assert errors_on(changeset).memberships == [%{group_id: ["can't be blank"]}]

      attrs = %{memberships: [%{actor_id: actor.id}]}
      assert {:error, changeset} = update_actor(actor, attrs, subject)
      assert errors_on(changeset).memberships == [%{group_id: ["can't be blank"]}]

      attrs = %{memberships: [%{group_id: Ecto.UUID.generate()}]}
      assert update_actor(actor, attrs, subject) == {:error, :rollback}
    end

    test "does not allow to remove membership of a synced group", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group)

      attrs = %{memberships: []}
      assert {:ok, %{memberships: []}} = update_actor(actor, attrs, subject)
      assert membership = Repo.one(Actors.Membership)
      assert membership.group_id == group.id
      assert membership.actor_id == actor.id
    end

    test "does not allow to add membership of a synced group", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)

      attrs = %{memberships: [%{group_id: group.id}]}
      assert {:error, changeset} = update_actor(actor, attrs, subject)
      assert errors_on(changeset).memberships == [%{group_id: ["is reserved"]}]
    end
  end

  describe "disable_actor/2" do
    test "disables a given actor" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert {:ok, actor} = disable_actor(actor, subject)
      assert actor.disabled_at

      assert actor = Repo.get(Actors.Actor, actor.id)
      assert actor.disabled_at

      assert other_actor = Repo.get(Actors.Actor, other_actor.id)
      assert is_nil(other_actor.disabled_at)
    end

    test "deletes token and broadcasts message to disconnect the actor sessions" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{subject.token_id}")

      assert {:ok, _actor} = disable_actor(actor, subject)

      assert token = Repo.get(Domain.Tokens.Token, subject.token_id)
      assert token.deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "expires actor flows" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      client = Fixtures.Clients.create_client(account: account, identity: identity)

      Fixtures.Flows.create_flow(
        account: account,
        subject: subject,
        client: client
      )

      assert {:ok, _actor} = disable_actor(actor, subject)

      expires_at = Repo.one(Domain.Flows.Flow).expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now()) < 1
    end

    test "returns error when trying to disable the last admin actor" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert disable_actor(actor, subject) == {:error, :cant_disable_the_last_admin}
    end

    test "last admin check ignores admins in other accounts" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Actors.create_actor(type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert disable_actor(actor, subject) == {:error, :cant_disable_the_last_admin}
    end

    test "last admin check ignores disabled admins" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      {:ok, _other_actor} = disable_actor(other_actor, subject)

      assert disable_actor(actor, subject) == {:error, :cant_disable_the_last_admin}
    end

    test "does not do anything when an actor is disabled twice" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert {:ok, _actor} = disable_actor(other_actor, subject)
      assert {:ok, other_actor} = disable_actor(other_actor, subject)
      assert {:ok, _actor} = disable_actor(other_actor, subject)
    end

    test "does not allow to disable actors in other accounts" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert disable_actor(other_actor, subject) == {:error, :not_found}
    end

    test "returns error when subject can not disable actors" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      subject =
        Fixtures.Auth.create_subject(account: account, actor: actor)
        |> Fixtures.Auth.remove_permissions()

      assert disable_actor(actor, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "enable_actor/2" do
    test "enables a given actor" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, actor} = disable_actor(actor, subject)

      assert {:ok, actor} = enable_actor(actor, subject)
      refute actor.disabled_at

      assert actor = Repo.get(Actors.Actor, actor.id)
      refute actor.disabled_at

      assert other_actor = Repo.get(Actors.Actor, other_actor.id)
      assert is_nil(other_actor.disabled_at)
    end

    test "does not do anything when an actor is already enabled" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, other_actor} = disable_actor(other_actor, subject)

      assert {:ok, _actor} = enable_actor(other_actor, subject)
      assert {:ok, other_actor} = enable_actor(other_actor, subject)
      assert {:ok, _actor} = enable_actor(other_actor, subject)
    end

    test "does not allow to enable actors in other accounts" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert enable_actor(other_actor, subject) == {:error, :not_found}
    end

    test "returns error when subject can not enable actors" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      subject =
        Fixtures.Auth.create_subject(account: account, actor: actor)
        |> Fixtures.Auth.remove_permissions()

      assert enable_actor(actor, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "delete_actor/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "deletes a given actor", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      assert {:ok, actor} = delete_actor(actor, subject)
      assert actor.deleted_at

      assert actor = Repo.get(Actors.Actor, actor.id)
      assert actor.deleted_at

      assert other_actor = Repo.get(Actors.Actor, other_actor.id)
      assert is_nil(other_actor.deleted_at)
    end

    test "deletes token and broadcasts message to disconnect the actor sessions", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{subject.token_id}")

      assert {:ok, _actor} = delete_actor(actor, subject)

      assert token = Repo.get(Domain.Tokens.Token, subject.token_id)
      assert token.deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "deletes actor identities", %{
      account: account,
      subject: subject
    } do
      actor_to_delete = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Auth.create_identity(account: account, actor: actor_to_delete)

      assert {:ok, actor} = delete_actor(actor_to_delete, subject)
      assert actor.deleted_at

      assert Repo.aggregate(Domain.Auth.Identity.Query.not_deleted(), :count) == 1
    end

    test "deletes actor clients", %{
      account: account,
      subject: subject
    } do
      actor_to_delete = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Clients.create_client(account: account, actor: actor_to_delete)

      assert {:ok, actor} = delete_actor(actor_to_delete, subject)
      assert actor.deleted_at

      assert Repo.aggregate(Domain.Clients.Client.Query.not_deleted(), :count) == 0
    end

    test "deletes actor memberships", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      Fixtures.Actors.create_membership(account: account, actor: actor)

      :ok = subscribe_for_membership_updates_for_actor(actor)

      assert {:ok, _actor} = delete_actor(actor, subject)

      assert Repo.aggregate(Actors.Membership, :count) == 0

      assert_receive {:delete_membership, actor_id, _group_id}
      assert actor_id == actor.id
    end

    test "expires actor flows", %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, identity: identity)

      Fixtures.Flows.create_flow(
        account: account,
        subject: subject,
        client: client
      )

      assert {:ok, _actor} = delete_actor(actor, subject)

      expires_at = Repo.one(Domain.Flows.Flow).expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now()) < 1
    end

    test "returns error when trying to delete the last admin actor", %{
      actor: actor,
      subject: subject
    } do
      assert delete_actor(actor, subject) == {:error, :cant_delete_the_last_admin}
    end

    test "last admin check ignores admins in other accounts", %{
      actor: actor,
      subject: subject
    } do
      Fixtures.Actors.create_actor(type: :account_admin_user)

      assert delete_actor(actor, subject) == {:error, :cant_delete_the_last_admin}
    end

    test "last admin check ignores disabled admins", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      {:ok, _other_actor} = disable_actor(other_actor, subject)

      assert delete_actor(actor, subject) == {:error, :cant_delete_the_last_admin}
    end

    test "last admin check ignores service accounts", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      service_account_actor =
        Fixtures.Actors.create_actor(
          type: :service_account,
          account: account
        )

      assert delete_actor(actor, subject) == {:error, :cant_delete_the_last_admin}

      assert {:ok, service_account_actor} = delete_actor(service_account_actor, subject)
      assert service_account_actor.deleted_at
    end

    test "returns error when trying to delete the last admin actor using a race condition" do
      for _ <- 0..50 do
        test_pid = self()

        Task.async(fn ->
          allow_child_sandbox_access(test_pid)

          Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

          account = Fixtures.Accounts.create_account()
          provider = Fixtures.Auth.create_email_provider(account: account)

          actor_one =
            Fixtures.Actors.create_actor(
              type: :account_admin_user,
              account: account,
              provider: provider
            )

          actor_two =
            Fixtures.Actors.create_actor(
              type: :account_admin_user,
              account: account,
              provider: provider
            )

          identity_one =
            Fixtures.Auth.create_identity(
              account: account,
              actor: actor_one,
              provider: provider
            )

          identity_two =
            Fixtures.Auth.create_identity(
              account: account,
              actor: actor_two,
              provider: provider
            )

          subject_one = Fixtures.Auth.create_subject(identity: identity_one)
          subject_two = Fixtures.Auth.create_subject(identity: identity_two)

          for {actor, subject} <- [{actor_two, subject_one}, {actor_one, subject_two}] do
            Task.async(fn ->
              allow_child_sandbox_access(test_pid)
              delete_actor(actor, subject)
            end)
          end
          |> Task.await_many()

          assert Repo.aggregate(Actors.Actor.Query.by_account_id(account.id), :count) == 1
        end)
      end
      |> Task.await_many()
    end

    test "does not allow to delete an actor twice", %{
      account: account,
      subject: subject
    } do
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      assert {:ok, _actor} = delete_actor(other_actor, subject)
      assert delete_actor(other_actor, subject) == {:error, :not_found}
    end

    test "does not allow to delete actors in other accounts", %{
      subject: subject
    } do
      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user)

      assert delete_actor(other_actor, subject) == {:error, :not_found}
    end

    test "returns error when subject can not delete actors" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      subject =
        Fixtures.Auth.create_subject(account: account, actor: actor)
        |> Fixtures.Auth.remove_permissions()

      assert delete_actor(actor, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  defp allow_child_sandbox_access(parent_pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Repo, parent_pid, self())
    # Allow is async call we need to break current process execution
    # to allow sandbox to be enabled
    :timer.sleep(10)
  end
end
