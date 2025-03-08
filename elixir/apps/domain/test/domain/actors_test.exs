defmodule Domain.ActorsTest do
  use Domain.DataCase, async: true
  import Domain.Actors
  alias Domain.Auth
  alias Domain.Clients
  alias Domain.Actors

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
      assert {:ok, [], _metadata} = list_groups(subject)
    end

    test "does not list groups from other accounts", %{
      subject: subject
    } do
      Fixtures.Actors.create_group()
      assert {:ok, [], _metadata} = list_groups(subject)
    end

    test "does not list deleted groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Actors.create_group(account: account)
      |> Fixtures.Actors.delete_group()

      assert {:ok, [], _metadata} = list_groups(subject)
    end

    test "returns all groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_group()

      assert {:ok, groups, _metadata} = list_groups(subject)
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

  describe "list_editable_groups/1" do
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
      assert {:ok, [], _metadata} = list_editable_groups(subject)
    end

    test "does not list groups from other accounts", %{
      subject: subject
    } do
      Fixtures.Actors.create_group()
      assert {:ok, [], _metadata} = list_editable_groups(subject)
    end

    test "does not list deleted groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Actors.create_group(account: account)
      |> Fixtures.Actors.delete_group()

      assert {:ok, [], _metadata} = list_editable_groups(subject)
    end

    test "returns all editable groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_managed_group(account: account)
      Fixtures.Actors.create_group()

      assert {:ok, groups, _metadata} = list_editable_groups(subject)
      assert length(groups) == 2
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_editable_groups(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "list_groups_for/2" do
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

    test "returns empty list when there are no groups", %{actor: actor, subject: subject} do
      assert {:ok, [], _metadata} = list_groups_for(actor, subject)
    end

    test "does not list groups from other accounts", %{actor: actor, subject: subject} do
      Fixtures.Actors.create_group()
      assert {:ok, [], _metadata} = list_groups_for(actor, subject)
    end

    test "does not list groups from other actors in account", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      actor2 = Fixtures.Actors.create_actor(account: account)
      group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor2, group: group)

      assert {:ok, [], _metadata} = list_groups_for(actor, subject)
    end

    test "does not list deleted groups", %{account: account, actor: actor, subject: subject} do
      group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group)

      Fixtures.Actors.delete_group(group)

      assert {:ok, [], _metadata} = list_groups_for(actor, subject)
    end

    test "returns all groups for actor", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      group1 = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group1)

      group2 = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group2)

      Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_group()

      assert {:ok, groups, _metadata} = list_groups_for(actor, subject)
      assert length(groups) == 2
    end

    test "returns error when subject has no permission to manage groups", %{
      actor: actor,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_groups_for(actor, subject) ==
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

    test "preloads group providers", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group)

      assert {:ok, peek} = peek_actor_groups([actor], 3, subject)
      assert [%Actors.Group{} = group] = peek[actor.id].items
      assert Ecto.assoc_loaded?(group.provider)
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

  describe "peek_actor_clients/3" do
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

    test "returns count of clients per actor and first 3 clients", %{
      account: account,
      subject: subject
    } do
      actor1 = Fixtures.Actors.create_actor(account: account)
      Fixtures.Clients.create_client(account: account, actor: actor1)
      Fixtures.Clients.create_client(account: account, actor: actor1)
      Fixtures.Clients.create_client(account: account, actor: actor1)
      Fixtures.Clients.create_client(account: account, actor: actor1)

      actor2 = Fixtures.Actors.create_actor(account: account)

      assert {:ok, peek} = peek_actor_clients([actor1, actor2], 3, subject)

      assert length(Map.keys(peek)) == 2

      assert peek[actor1.id].count == 4
      assert length(peek[actor1.id].items) == 3
      assert [%Clients.Client{} | _] = peek[actor1.id].items

      assert peek[actor2.id].count == 0
      assert Enum.empty?(peek[actor2.id].items)
    end

    test "preloads client presence", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      Domain.Clients.connect_client(client)

      assert {:ok, peek} = peek_actor_clients([actor], 3, subject)
      assert [%Clients.Client{} = client] = peek[actor.id].items
      assert client.online?
    end

    test "returns count of clients per actor and first LIMIT clients", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Clients.create_client(account: account, actor: actor)
      Fixtures.Clients.create_client(account: account, actor: actor)

      other_actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Clients.create_client(account: account, actor: other_actor)

      assert {:ok, peek} = peek_actor_clients([actor], 1, subject)
      assert length(peek[actor.id].items) == 1
      assert Enum.count(peek) == 1
    end

    test "ignores deleted clients", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Clients.create_client(account: account, actor: actor)
      |> Fixtures.Clients.delete_client()

      assert {:ok, peek} = peek_actor_clients([actor], 3, subject)
      assert peek[actor.id].count == 0
      assert Enum.empty?(peek[actor.id].items)
    end

    test "ignores other clients", %{
      account: account,
      subject: subject
    } do
      Fixtures.Clients.create_client(account: account)
      Fixtures.Clients.create_client(account: account)

      actor = Fixtures.Actors.create_actor(account: account)

      assert {:ok, peek} = peek_actor_clients([actor], 1, subject)
      assert peek[actor.id].count == 0
      assert Enum.empty?(peek[actor.id].items)
    end

    test "returns empty map on empty actors", %{subject: subject} do
      assert peek_actor_clients([], 1, subject) == {:ok, %{}}
    end

    test "returns empty map on empty clients", %{account: account, subject: subject} do
      actor = Fixtures.Actors.create_actor(account: account)

      assert {:ok, peek} = peek_actor_clients([actor], 3, subject)

      assert length(Map.keys(peek)) == 1
      assert peek[actor.id].count == 0
      assert Enum.empty?(peek[actor.id].items)
    end

    test "does not allow peeking into other accounts", %{
      subject: subject
    } do
      other_account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: other_account)
      Fixtures.Clients.create_client(account: other_account, actor: actor)

      assert {:ok, peek} = peek_actor_clients([actor], 3, subject)
      assert Map.has_key?(peek, actor.id)
      assert peek[actor.id].count == 0
      assert Enum.empty?(peek[actor.id].items)
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert peek_actor_clients([], 3, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Domain.Clients.Authorizer.manage_clients_permission()]}}
    end
  end

  describe "sync_provider_groups/2" do
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

      assert {:ok,
              %{
                plan: {upsert, []},
                deleted: [],
                upserted: [_group1, _group2],
                group_ids_by_provider_identifier: group_ids_by_provider_identifier
              }} = sync_provider_groups(provider, attrs_list)

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

      assert {:ok,
              %{
                plan: {upsert, []},
                deleted: [],
                upserted: [_group1, _group2],
                group_ids_by_provider_identifier: group_ids_by_provider_identifier
              }} = sync_provider_groups(provider, attrs_list)

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

    test "deletes removed groups and broadcasts events for them", %{
      account: account,
      provider: provider
    } do
      group1 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:GROUP_ID1"
        )

      group1_policy = Fixtures.Policies.create_policy(account: account, actor_group: group1)

      actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group1)

      group1_flow =
        Fixtures.Flows.create_flow(
          account: account,
          actor_group: group1,
          resource_id: group1_policy.resource_id,
          policy: group1_policy
        )

      group2 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "OU:OU_ID1"
        )

      :ok = subscribe_to_membership_updates_for_actor(actor)
      :ok = Domain.Policies.subscribe_to_events_for_actor(actor)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(group1)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(group2)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(group1_flow)

      attrs_list = []

      assert {:ok,
              %{
                groups: [_group1, _group2],
                plan: {[], delete},
                deleted: [deleted_group1, deleted_group2],
                upserted: [],
                group_ids_by_provider_identifier: group_ids_by_provider_identifier
              }} = sync_provider_groups(provider, attrs_list)

      assert Enum.all?(["G:GROUP_ID1", "OU:OU_ID1"], &(&1 in delete))
      assert deleted_group1.provider_identifier in ["G:GROUP_ID1", "OU:OU_ID1"]
      assert deleted_group2.provider_identifier in ["G:GROUP_ID1", "OU:OU_ID1"]
      assert Repo.aggregate(Actors.Group, :count) == 2
      assert Repo.aggregate(Actors.Group.Query.not_deleted_or_excluded(), :count) == 0

      assert Enum.empty?(group_ids_by_provider_identifier)

      actor_id = actor.id

      group1_id = group1.id
      group1_policy_id = group1_policy.id
      group1_flow_id = group1_flow.id
      assert_receive {:delete_membership, ^actor_id, ^group1_id}
      assert_receive {:reject_access, ^group1_policy_id, ^group1_id, _resource_id}
      assert_receive {:expire_flow, ^group1_flow_id, _client_id, _resource_id}

      group2_id = group2.id
      refute_receive {:delete_membership, _actor_id, ^group2_id}
      refute_receive {:reject_access, _policy_id, ^group2_id, _resource_id}
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

      assert sync_provider_groups(provider, attrs_list) ==
               {:ok,
                %{
                  groups: [],
                  plan: {[], []},
                  deleted: [],
                  upserted: [],
                  group_ids_by_provider_identifier: %{}
                }}
    end
  end

  describe "sync_provider_memberships/2" do
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

      group1_policy = Fixtures.Policies.create_policy(account: account, actor_group: group1)

      group2 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "OU:OU_ID1"
        )

      group2_policy = Fixtures.Policies.create_policy(account: account, actor_group: group2)

      actor1 = Fixtures.Actors.create_actor(account: account)

      identity1 =
        Fixtures.Auth.create_identity(
          account: account,
          actor: actor1,
          provider: provider,
          provider_identifier: "USER_ID1"
        )

      actor2 = Fixtures.Actors.create_actor(account: account)

      identity2 =
        Fixtures.Auth.create_identity(
          account: account,
          actor: actor2,
          provider: provider,
          provider_identifier: "USER_ID2"
        )

      %{
        account: account,
        provider: provider,
        group1: group1,
        group2: group2,
        group1_policy: group1_policy,
        group2_policy: group2_policy,
        actor1: actor1,
        identity1: identity1,
        actor2: actor2,
        identity2: identity2,
        bypass: bypass
      }
    end

    test "creates new memberships", %{
      provider: provider,
      actor1: actor1,
      actor2: actor2,
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

      :ok = subscribe_to_membership_updates_for_actor(actor1)
      :ok = subscribe_to_membership_updates_for_actor(actor2)
      :ok = Domain.Policies.subscribe_to_events_for_actor(actor1)
      :ok = Domain.Policies.subscribe_to_events_for_actor(actor2)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(group1)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(group2)

      assert {:ok,
              %{
                plan: {insert, []},
                deleted_stats: {0, nil},
                inserted: [_membership1, _membership2]
              }} =
               sync_provider_memberships(
                 actor_ids_by_provider_identifier,
                 group_ids_by_provider_identifier,
                 provider,
                 tuples_list
               )

      assert {group1.id, identity1.actor_id} in insert
      assert {group2.id, identity2.actor_id} in insert

      memberships = Repo.all(Actors.Membership)
      assert length(memberships) == 2

      for membership <- memberships do
        assert {membership.group_id, membership.actor_id} in insert

        actor_id = membership.actor_id
        group_id = membership.group_id
        assert_receive {:create_membership, ^actor_id, ^group_id}
        assert_receive {:allow_access, _policy_id, ^group_id, _resource_id}
      end
    end

    test "ignores existing memberships", %{
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

      :ok = subscribe_to_membership_updates_for_actor(identity1.actor_id)
      :ok = subscribe_to_membership_updates_for_actor(identity2.actor_id)
      :ok = Domain.Policies.subscribe_to_events_for_actor(identity1.actor_id)
      :ok = Domain.Policies.subscribe_to_events_for_actor(identity2.actor_id)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(group1)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(group2)

      assert {:ok,
              %{
                plan: {[], []},
                deleted_stats: {0, nil},
                inserted: []
              }} =
               sync_provider_memberships(
                 actor_ids_by_provider_identifier,
                 group_ids_by_provider_identifier,
                 provider,
                 tuples_list
               )

      assert Repo.aggregate(Actors.Membership, :count) == 2
      assert Repo.aggregate(Actors.Membership.Query.all(), :count) == 2

      refute_receive {:create_membership, _actor_id, _group_id}
      refute_receive {:delete_membership, _actor_id, _group_id}
      refute_receive {:allow_access, _policy_id, _group_id, _resource_id}
      refute_receive {:reject_access, _policy_id, _group_id, _resource_id}
    end

    test "deletes removed memberships", %{
      account: account,
      provider: provider,
      group1: group1,
      group2: group2,
      actor1: actor1,
      identity1: identity1,
      identity2: identity2
    } do
      policy = Fixtures.Policies.create_policy(account: account, actor_group: group1)

      client =
        Fixtures.Clients.create_client(
          account: account,
          actor: actor1,
          identity: identity1
        )

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          actor_group: group1,
          client: client,
          resource_id: policy.resource_id,
          policy: policy
        )

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

      :ok = subscribe_to_membership_updates_for_actor(identity1.actor_id)
      :ok = subscribe_to_membership_updates_for_actor(identity2.actor_id)
      :ok = Domain.Policies.subscribe_to_events_for_actor(identity1.actor_id)
      :ok = Domain.Policies.subscribe_to_events_for_actor(identity2.actor_id)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(group1)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(group2)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(flow)

      assert {:ok,
              %{
                plan: {[], delete},
                deleted_stats: {2, nil},
                inserted: []
              }} =
               sync_provider_memberships(
                 actor_ids_by_provider_identifier,
                 group_ids_by_provider_identifier,
                 provider,
                 tuples_list
               )

      assert {group1.id, identity1.actor_id} in delete
      assert {group2.id, identity2.actor_id} in delete

      assert Repo.aggregate(Actors.Membership, :count) == 0
      assert Repo.aggregate(Actors.Membership.Query.all(), :count) == 0

      actor1_id = identity1.actor_id
      group1_id = group1.id
      assert_receive {:delete_membership, ^actor1_id, ^group1_id}
      assert_receive {:reject_access, _policy_id, ^group1_id, _resource_id}

      actor2_id = identity2.actor_id
      group2_id = group2.id
      assert_receive {:delete_membership, ^actor2_id, ^group2_id}
      assert_receive {:reject_access, _policy_id, ^group2_id, _resource_id}

      flow_id = flow.id
      assert_receive {:expire_flow, ^flow_id, _client_id, _resource_id}
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

      assert {:ok,
              %{
                plan: {[], delete},
                inserted: [],
                deleted_stats: {1, nil}
              }} =
               sync_provider_memberships(
                 actor_ids_by_provider_identifier,
                 group_ids_by_provider_identifier,
                 provider,
                 tuples_list
               )

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

      assert {:ok,
              %{
                plan: {[], []},
                deleted_stats: {0, nil},
                inserted: []
              }} =
               sync_provider_memberships(
                 actor_ids_by_provider_identifier,
                 group_ids_by_provider_identifier,
                 provider,
                 tuples_list
               )
    end

    test "deletes actors that are not processed by identity sync", %{
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

      actor_ids_by_provider_identifier = %{}

      group_ids_by_provider_identifier = %{
        group1.provider_identifier => group1.id,
        group2.provider_identifier => group2.id
      }

      assert {:ok,
              %{
                plan: {[], delete},
                deleted_stats: {2, nil},
                inserted: []
              }} =
               sync_provider_memberships(
                 actor_ids_by_provider_identifier,
                 group_ids_by_provider_identifier,
                 provider,
                 tuples_list
               )

      assert {group1.id, identity1.actor_id} in delete
      assert {group2.id, identity2.actor_id} in delete
    end

    test "deletes groups that are not processed by groups sync", %{
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

      group_ids_by_provider_identifier = %{}

      assert {:ok,
              %{
                plan: {[], delete},
                deleted_stats: {2, nil},
                inserted: []
              }} =
               sync_provider_memberships(
                 actor_ids_by_provider_identifier,
                 group_ids_by_provider_identifier,
                 provider,
                 tuples_list
               )

      assert {group1.id, identity1.actor_id} in delete
      assert {group2.id, identity2.actor_id} in delete
    end
  end

  describe "new_group/0" do
    test "returns group changeset" do
      assert %Ecto.Changeset{data: %Actors.Group{}, changes: changes} = new_group()
      assert Enum.empty?(changes)
    end
  end

  describe "create_managed_group/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      %{
        account: account
      }
    end

    test "returns error on empty attrs", %{account: account} do
      assert {:error, changeset} = create_managed_group(account, %{})

      assert errors_on(changeset) == %{
               name: ["can't be blank"],
               membership_rules: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{account: account} do
      attrs = %{name: String.duplicate("A", 256)}
      assert {:error, changeset} = create_managed_group(account, attrs)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"],
               membership_rules: ["can't be blank"]
             }

      Fixtures.Actors.create_managed_group(account: account, name: "foo")
      attrs = %{name: "foo", type: :static, membership_rules: [%{operator: true}]}
      assert {:error, changeset} = create_managed_group(account, attrs)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "creates a group", %{account: account} do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      :ok = subscribe_to_membership_updates_for_actor(actor)

      attrs = Fixtures.Actors.group_attrs(membership_rules: [%{operator: true}])

      assert {:ok, group} = create_managed_group(account, attrs)
      assert group.id
      assert group.name == attrs.name

      group = Repo.preload(group, :memberships)
      assert [membership] = group.memberships
      assert membership.group_id == group.id
      assert membership.actor_id == identity.actor_id

      assert_receive {:create_membership, actor_id, group_id}
      assert actor_id == actor.id
      assert group_id == group.id
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

      assert errors_on(changeset) == %{
               name: ["can't be blank"],
               type: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      attrs = %{name: String.duplicate("A", 256), type: :foo}
      assert {:error, changeset} = create_group(attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"],
               type: ["is invalid"]
             }

      Fixtures.Actors.create_group(account: account, name: "foo")
      attrs = %{name: "foo", type: :static}
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

      :ok = subscribe_to_membership_updates_for_actor(actor)

      assert {:ok, group} = create_group(attrs, subject)
      assert group.id
      assert group.name == attrs.name
      assert group.type == attrs.type

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

      attrs =
        Fixtures.Actors.group_attrs(
          memberships: [
            %{actor_id: actor.id}
          ]
        )

      assert changeset = change_group(group, attrs)
      assert changeset.valid?

      assert %{name: name, memberships: [membership]} = changeset.changes
      assert name == attrs.name
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

    test "raises if group is managed" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_managed_group(account: account, provider: provider)

      assert_raise ArgumentError, "can't change managed groups", fn ->
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

      attrs = %{name: String.duplicate("A", 256)}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert errors_on(changeset) == %{name: ["should be at most 255 character(s)"]}

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

    test "updates dynamic group membership rules", %{account: account, subject: subject} do
      group =
        Fixtures.Actors.create_group(
          type: :dynamic,
          account: account,
          membership_rules: [%{operator: true}]
        )

      attrs =
        Fixtures.Actors.group_attrs(
          membership_rules: [
            %{path: ["claims", "group"], operator: "contains", values: ["admin"]}
          ]
        )

      assert {:ok, group} = update_group(group, attrs, subject)

      assert group.membership_rules == [
               %Domain.Actors.MembershipRule{
                 path: ["claims", "group"],
                 operator: :contains,
                 values: ["admin"]
               }
             ]
    end

    test "updates dynamic group memberships", %{
      account: account,
      subject: subject
    } do
      group =
        Fixtures.Actors.create_group(
          type: :dynamic,
          account: account,
          membership_rules: [
            %{path: ["claims", "email"], operator: "is_in", values: ["xxx@fz.one"]}
          ]
        )

      assert Repo.aggregate(Actors.Membership.Query.by_group_id(group.id), :count) == 0

      attrs = %{membership_rules: [%{operator: "true"}]}
      assert {:ok, %{memberships: memberships}} = update_group(group, attrs, subject)
      assert length(memberships) == 2
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
      :ok = subscribe_to_membership_updates_for_actor(actor1)
      :ok = subscribe_to_membership_updates_for_actor(actor2)
      :ok = Domain.Policies.subscribe_to_events_for_actor(actor1)
      :ok = Domain.Policies.subscribe_to_events_for_actor(actor2)

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

    test "returns error if group is synced", %{
      account: account,
      subject: subject
    } do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)

      assert update_group(group, %{}, subject) == {:error, :synced_group}
    end

    test "returns error if group is managed", %{
      account: account,
      subject: subject
    } do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_managed_group(account: account, provider: provider)

      assert update_group(group, %{}, subject) == {:error, :managed_group}
    end
  end

  describe "update_dynamic_group_memberships/1" do
    test "updates memberships" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_group(
        type: :dynamic,
        membership_rules: [%{operator: true}],
        account: account
      )

      identity = Fixtures.Auth.create_identity(account: account)

      assert {:ok, [_group]} = update_dynamic_group_memberships(account.id)

      assert memberships = Repo.all(Actors.Membership)
      assert length(memberships) == 2
      assert Enum.any?(memberships, fn membership -> membership.actor_id == identity.actor_id end)
    end

    test "broadcasts events" do
      account = Fixtures.Accounts.create_account()

      group =
        Fixtures.Actors.create_group(
          type: :dynamic,
          membership_rules: [%{operator: true}],
          account: account
        )

      actor = Fixtures.Actors.create_actor(account: account)
      :ok = subscribe_to_membership_updates_for_actor(actor)

      # this function will call update_dynamic_group_memberships by itself
      Fixtures.Auth.create_identity(account: account, actor: actor)

      assert_receive {:create_membership, actor_id, group_id}
      assert actor_id == actor.id
      assert group_id == group.id

      # doesn't broadcast events when memberships are not changed
      assert {:ok, [_group]} = update_dynamic_group_memberships(account.id)
      refute_receive {:create_membership, _actor_id, _group_id}
    end

    test "allows to use is_in operator" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_group(
        type: :dynamic,
        membership_rules: [%{path: ["claims", "group"], operator: :is_in, values: ["admin"]}],
        account: account
      )

      identity =
        Fixtures.Auth.create_identity(account: account)
        |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "admin"}})
        |> Repo.update!()

      assert {:ok, [_group]} = update_dynamic_group_memberships(account.id)

      assert membership = Repo.one(Actors.Membership)
      assert membership.actor_id == identity.actor_id
    end

    test "allows to use is_not_in operator" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_group(
        type: :dynamic,
        membership_rules: [%{path: ["claims", "group"], operator: :is_not_in, values: ["user"]}],
        account: account
      )

      identity =
        Fixtures.Auth.create_identity(account: account)
        |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "admin"}})
        |> Repo.update!()

      assert {:ok, [_group]} = update_dynamic_group_memberships(account.id)

      assert membership = Repo.one(Actors.Membership)
      assert membership.actor_id == identity.actor_id
    end

    test "allows to use contains operator" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_group(
        type: :dynamic,
        membership_rules: [%{path: ["claims", "group"], operator: :contains, values: ["ad"]}],
        account: account
      )

      identity =
        Fixtures.Auth.create_identity(account: account)
        |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "admin"}})
        |> Repo.update!()

      assert {:ok, [_group]} = update_dynamic_group_memberships(account.id)

      assert membership = Repo.one(Actors.Membership)
      assert membership.actor_id == identity.actor_id
    end

    test "allows to use does_not_contain operator" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_group(
        type: :dynamic,
        membership_rules: [
          %{path: ["claims", "group"], operator: :does_not_contain, values: ["usr"]}
        ],
        account: account
      )

      identity =
        Fixtures.Auth.create_identity(account: account)
        |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "admin"}})
        |> Repo.update!()

      assert {:ok, [_group]} = update_dynamic_group_memberships(account.id)

      assert membership = Repo.one(Actors.Membership)
      assert membership.actor_id == identity.actor_id
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

      :ok = subscribe_to_membership_updates_for_actor(actor)

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

  describe "group_synced?/1" do
    test "returns true for synced groups" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)
      assert group_synced?(group) == true
    end

    test "returns false for manually created groups" do
      group = Fixtures.Actors.create_group()
      assert group_synced?(group) == false
    end
  end

  describe "group_managed?/1" do
    test "returns true for managed groups" do
      account = Fixtures.Accounts.create_account()
      group = Fixtures.Actors.create_managed_group(account: account)
      assert group_managed?(group) == true
    end

    test "returns false for manually created groups" do
      group = Fixtures.Actors.create_group()
      assert group_managed?(group) == false
    end
  end

  describe "group_editable?/1" do
    test "returns false for synced groups" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      group = Fixtures.Actors.create_group(account: account, provider: provider)
      assert group_editable?(group) == false
    end

    test "returns false for managed groups" do
      account = Fixtures.Accounts.create_account()
      group = Fixtures.Actors.create_managed_group(account: account)
      assert group_editable?(group) == false
    end

    test "returns false for manually created groups" do
      group = Fixtures.Actors.create_group()
      assert group_editable?(group) == true
    end
  end

  describe "group_deleted?/1" do
    test "returns true for deleted groups" do
      account = Fixtures.Accounts.create_account()
      group = Fixtures.Actors.create_group(account: account) |> Fixtures.Actors.delete_group()
      assert group_deleted?(group) == true
    end

    test "returns false for manually created groups" do
      group = Fixtures.Actors.create_group()
      assert group_deleted?(group) == false
    end
  end

  describe "count_users_for_account/1" do
    test "returns 0 when actors are in another account", %{} do
      account = Fixtures.Accounts.create_account()
      Fixtures.Actors.create_actor(type: :account_admin_user)

      assert count_users_for_account(account) == 0
    end

    test "returns count of account users" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Actors.create_actor(type: :account_user, account: account)

      assert count_users_for_account(account) == 2
    end

    test "does not count disabled" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_actor(type: :account_user, account: account)
      |> Fixtures.Actors.disable()

      assert count_users_for_account(account) == 0
    end

    test "does not count deleted" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      |> Fixtures.Actors.delete()

      assert count_users_for_account(account) == 0
    end
  end

  describe "count_account_admin_users_for_account/1" do
    test "returns 0 when actors are in another account", %{} do
      account = Fixtures.Accounts.create_account()
      Fixtures.Actors.create_actor(type: :account_admin_user)

      assert count_account_admin_users_for_account(account) == 0
    end

    test "returns count of account admin actors" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      assert count_account_admin_users_for_account(account) == 2
    end

    test "does not count non account admin actors" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Actors.create_actor(type: :account_user, account: account)

      assert count_account_admin_users_for_account(account) == 0
    end

    test "does not count disabled account admin actors" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      |> Fixtures.Actors.disable()

      assert count_account_admin_users_for_account(account) == 0
    end

    test "does not count deleted account admin actors" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      |> Fixtures.Actors.delete()

      assert count_account_admin_users_for_account(account) == 0
    end
  end

  describe "count_service_accounts_for_account/1" do
    test "returns 0 when actors are in another account", %{} do
      account = Fixtures.Accounts.create_account()
      Fixtures.Actors.create_actor(type: :service_account)

      assert count_service_accounts_for_account(account) == 0
    end

    test "returns count of service account actors" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Actors.create_actor(type: :service_account, account: account)
      Fixtures.Actors.create_actor(type: :service_account, account: account)

      assert count_service_accounts_for_account(account) == 2
    end

    test "does not count non service account actors" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Actors.create_actor(type: :account_user, account: account)
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      assert count_service_accounts_for_account(account) == 0
    end

    test "does not count disabled service account actors" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_actor(type: :service_account, account: account)
      |> Fixtures.Actors.disable()

      assert count_service_accounts_for_account(account) == 0
    end

    test "does not count deleted service account actors" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Actors.create_actor(type: :service_account, account: account)
      |> Fixtures.Actors.delete()

      assert count_service_accounts_for_account(account) == 0
    end
  end

  describe "count_synced_actors_for_provider/1" do
    test "returns 0 when there are no actors" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      assert count_synced_actors_for_provider(provider) == 0
    end

    test "returns 0 when there are no synced actors" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      assert count_synced_actors_for_provider(provider) == 0
    end

    test "returns count of synced actors owned only by the given provider" do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      actor1 =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account
        )

      Fixtures.Auth.create_identity(account: account, actor: actor1, provider: provider)
      |> Fixtures.Auth.delete_identity()

      actor2 =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account
        )

      Fixtures.Auth.create_identity(account: account, actor: actor2, provider: provider)
      |> Fixtures.Auth.delete_identity()

      actor3 =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account
        )

      Fixtures.Auth.create_identity(account: account, actor: actor3)
      |> Fixtures.Auth.delete_identity()

      actor4 =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account
        )

      Fixtures.Auth.create_identity(account: account, actor: actor4, provider: provider)
      |> Fixtures.Auth.delete_identity()

      Fixtures.Auth.create_identity(account: account, actor: actor4)
      |> Fixtures.Auth.delete_identity()

      actor5 =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account
        )

      Fixtures.Auth.create_identity(account: account, actor: actor5, provider: provider)

      assert count_synced_actors_for_provider(provider) == 2
    end
  end

  describe "fetch_actor_by_id/3" do
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

    test "returns error when subject cannot view actors" do
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

  describe "fetch_active_actor_by_id/1" do
    test "returns error when actor is not found" do
      assert fetch_active_actor_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUIDv4" do
      assert fetch_active_actor_by_id("foo") == {:error, :not_found}
    end

    test "returns error when actor is disabled" do
      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user)
        |> Fixtures.Actors.disable()

      assert fetch_active_actor_by_id(actor.id) == {:error, :not_found}
    end

    test "returns error when actor is deleted" do
      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user)
        |> Fixtures.Actors.delete()

      assert fetch_active_actor_by_id(actor.id) == {:error, :not_found}
    end

    test "returns actor" do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user)
      assert {:ok, returned_actor} = fetch_active_actor_by_id(actor.id)
      assert returned_actor.id == actor.id
    end
  end

  describe "all_actor_group_ids!/1" do
    test "returns list of all group ids where an actor is a member" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account)

      group1 = Fixtures.Actors.create_group(account: account)
      group2 = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_group(account: account)

      Fixtures.Actors.create_membership(account: account, actor: actor, group: group1)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group2)

      assert Enum.sort(all_actor_group_ids!(actor)) == Enum.sort([group1.id, group2.id])
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

      assert {:ok, [], _metadata} = list_actors(subject)
    end

    test "returns list of actors in all types" do
      account = Fixtures.Accounts.create_account()
      actor1 = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      actor2 = Fixtures.Actors.create_actor(account: account, type: :account_user)
      Fixtures.Actors.create_actor(type: :account_user)

      identity1 = Fixtures.Auth.create_identity(account: account, actor: actor1)
      subject = Fixtures.Auth.create_subject(identity: identity1)

      assert {:ok, actors, _metadata} = list_actors(subject)
      assert length(actors) == 2
      assert Enum.sort(Enum.map(actors, & &1.id)) == Enum.sort([actor1.id, actor2.id])
    end

    test "returns error when subject cannot view actors" do
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

      {:ok, actors, _metadata} = list_actors(subject, preload: :identities)
      assert length(actors) == 2

      assert Enum.all?(actors, fn a -> Ecto.assoc_loaded?(a.identities) end)
    end
  end

  describe "create_actor/2" do
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

  describe "create_actor/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor)

      %{
        account: account,
        actor: actor,
        subject: subject
      }
    end

    test "creates an actor", %{
      account: account,
      subject: subject
    } do
      attrs = Fixtures.Actors.actor_attrs()

      assert {:ok, actor} = create_actor(account, attrs, subject)

      assert actor.type == attrs.type
      assert actor.type == attrs.type
      assert is_nil(actor.disabled_at)
      assert is_nil(actor.deleted_at)
    end

    test "returns error when seats limit is exceeded (admins)", %{
      account: account,
      subject: subject
    } do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{
            monthly_active_users_count: 1
          }
        })

      Fixtures.Clients.create_client(actor: [type: :account_admin_user], account: account)

      attrs = Fixtures.Actors.actor_attrs()

      assert create_actor(account, attrs, subject) == {:error, :seats_limit_reached}
    end

    test "returns error when admins limit is exceeded", %{
      account: account,
      subject: subject
    } do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{
            account_admin_users_count: 1
          }
        })

      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      attrs = Fixtures.Actors.actor_attrs(type: :account_admin_user)

      assert create_actor(account, attrs, subject) == {:error, :seats_limit_reached}
    end

    test "returns error when seats limit is exceeded (users)", %{
      account: account,
      subject: subject
    } do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{
            monthly_active_users_count: 1
          }
        })

      Fixtures.Clients.create_client(actor: [type: :account_user], account: account)

      attrs = Fixtures.Actors.actor_attrs()

      assert create_actor(account, attrs, subject) == {:error, :seats_limit_reached}
    end

    test "returns error when service accounts limit is exceeded", %{
      account: account,
      subject: subject
    } do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{
            service_accounts_count: 1
          }
        })

      Fixtures.Actors.create_actor(type: :service_account, account: account)

      attrs = Fixtures.Actors.actor_attrs(type: :service_account)

      assert create_actor(account, attrs, subject) == {:error, :service_accounts_limit_reached}
    end

    test "returns error when subject cannot create actors", %{
      account: account,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

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
      account: account,
      subject: subject
    } do
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

    test "returns error when subject cannot manage types", %{account: account} do
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
      :ok = subscribe_to_membership_updates_for_actor(actor)
      :ok = Domain.Policies.subscribe_to_events_for_actor(actor)

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
      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 1
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

    test "returns error when subject cannot disable actors" do
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

    test "returns error when subject cannot enable actors" do
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

    test "updates dynamic groups memberships", %{account: account, actor: actor, subject: subject} do
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      group = Fixtures.Actors.create_managed_group(account: account)

      assert {:ok, actor} = delete_actor(actor, subject)
      assert actor.deleted_at

      group = Repo.preload(group, :memberships, force: true)
      assert group.memberships == []
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

      :ok = subscribe_to_membership_updates_for_actor(actor)

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
      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 1
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

          queryable =
            Actors.Actor.Query.not_deleted()
            |> Actors.Actor.Query.by_account_id(account.id)

          assert Repo.aggregate(queryable, :count) == 1
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

    test "returns error when subject cannot delete actors" do
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

  describe "delete_stale_synced_actors_for_provider/2" do
    test "deletes actors synced with only the given provider" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Auth.create_subject(account: account)

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      actor1 =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account
        )

      Fixtures.Auth.create_identity(account: account, actor: actor1, provider: provider)
      |> Fixtures.Auth.delete_identity()

      actor2 =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account
        )

      Fixtures.Auth.create_identity(account: account, actor: actor2, provider: provider)
      |> Fixtures.Auth.delete_identity()

      actor3 =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account
        )

      Fixtures.Auth.create_identity(account: account, actor: actor3)
      |> Fixtures.Auth.delete_identity()

      actor4 =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account
        )

      Fixtures.Auth.create_identity(account: account, actor: actor4, provider: provider)
      |> Fixtures.Auth.delete_identity()

      Fixtures.Auth.create_identity(account: account, actor: actor4)
      |> Fixtures.Auth.delete_identity()

      assert delete_stale_synced_actors_for_provider(provider, subject) == :ok
      not_deleted_actors = Repo.all(Actors.Actor.Query.not_deleted())
      not_deleted_actor_ids = not_deleted_actors |> Enum.map(& &1.id) |> Enum.sort()

      assert not_deleted_actor_ids == Enum.sort([actor4.id, actor3.id, subject.actor.id])
    end

    test "returns error when subject cannot delete actors" do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      subject =
        Fixtures.Auth.create_subject(account: account)
        |> Fixtures.Auth.remove_permissions()

      assert delete_stale_synced_actors_for_provider(provider, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Actors.Authorizer.manage_actors_permission()]}}
    end
  end

  describe "actor_synced?/1" do
    test "returns true when actor is synced" do
      actor = Fixtures.Actors.create_actor()
      actor = Fixtures.Actors.update(actor, last_synced_at: DateTime.utc_now())

      assert actor_synced?(actor) == true
    end

    test "returns false when actor is not synced" do
      actor = Fixtures.Actors.create_actor()
      actor = Fixtures.Actors.update(actor, last_synced_at: nil)

      assert actor_synced?(actor) == false
    end
  end

  describe "actor_deleted?/1" do
    test "returns true when actor is deleted" do
      actor =
        Fixtures.Actors.create_actor()
        |> Fixtures.Actors.delete()

      assert actor_deleted?(actor) == true
    end

    test "returns false when actor is not deleted" do
      actor = Fixtures.Actors.create_actor()

      assert actor_deleted?(actor) == false
    end
  end

  describe "actor_disabled?/1" do
    test "returns true when actor is disabled" do
      actor =
        Fixtures.Actors.create_actor()
        |> Fixtures.Actors.disable()

      assert actor_disabled?(actor) == true
    end

    test "returns false when actor is not disabled" do
      actor = Fixtures.Actors.create_actor()

      assert actor_disabled?(actor) == false
    end
  end

  defp allow_child_sandbox_access(parent_pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Repo, parent_pid, self())
    # Allow is async call we need to break current process execution
    # to allow sandbox to be enabled
    :timer.sleep(10)
  end
end
