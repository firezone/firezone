defmodule Domain.ActorsTest do
  use Domain.DataCase, async: true
  import Domain.Actors
  alias Domain.Auth
  alias Domain.Actors
  alias Domain.{AccountsFixtures, AuthFixtures, ActorsFixtures}

  describe "fetch_group_by_id/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

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
      group = ActorsFixtures.create_group()
      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "does not return deleted groups", %{
      account: account,
      subject: subject
    } do
      group =
        ActorsFixtures.create_group(account: account)
        |> ActorsFixtures.delete_group()

      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "returns group by id", %{account: account, subject: subject} do
      group = ActorsFixtures.create_group(account: account)
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      group = ActorsFixtures.create_group(account: account)
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
      subject = AuthFixtures.remove_permissions(subject)

      assert fetch_group_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "list_groups/1" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

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
      ActorsFixtures.create_group()
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list deleted groups", %{
      account: account,
      subject: subject
    } do
      ActorsFixtures.create_group(account: account)
      |> ActorsFixtures.delete_group()

      assert list_groups(subject) == {:ok, []}
    end

    test "returns all groups", %{
      account: account,
      subject: subject
    } do
      ActorsFixtures.create_group(account: account)
      ActorsFixtures.create_group(account: account)
      ActorsFixtures.create_group()

      assert {:ok, groups} = list_groups(subject)
      assert length(groups) == 2
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert list_groups(subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "new_group/0" do
    test "returns group changeset" do
      assert %Ecto.Changeset{data: %Actors.Group{}, changes: changes} = new_group()
      assert Enum.count(changes) == 0
    end
  end

  describe "create_group/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

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

      ActorsFixtures.create_group(account: account, name: "foo")
      attrs = %{name: "foo", tokens: [%{}]}
      assert {:error, changeset} = create_group(attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "creates a group", %{subject: subject} do
      attrs = ActorsFixtures.group_attrs()

      assert {:ok, group} = create_group(attrs, subject)
      assert group.id
      assert group.name == attrs.name

      group = Repo.preload(group, :memberships)
      assert group.memberships == []
    end

    test "creates a group with memberships", %{account: account, actor: actor, subject: subject} do
      attrs =
        ActorsFixtures.group_attrs(
          memberships: [
            %{actor_id: actor.id}
          ]
        )

      assert {:ok, group} = create_group(attrs, subject)
      assert group.id
      assert group.name == attrs.name

      group = Repo.preload(group, :memberships)
      assert [%Actors.Membership{} = membership] = group.memberships
      assert membership.actor_id == actor.id
      assert membership.account_id == account.id
      assert membership.group_id == group.id
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert create_group(%{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "change_group/1" do
    test "returns changeset with given changes" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      group = ActorsFixtures.create_group(account: account)

      group_attrs =
        ActorsFixtures.group_attrs(
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
  end

  describe "update_group/3" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "does not allow to reset required fields to empty values", %{
      subject: subject
    } do
      group = ActorsFixtures.create_group()
      attrs = %{name: nil}

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      group = ActorsFixtures.create_group(account: account)

      attrs = %{name: String.duplicate("A", 65)}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert errors_on(changeset) == %{name: ["should be at most 64 character(s)"]}

      ActorsFixtures.create_group(account: account, name: "foo")
      attrs = %{name: "foo"}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "updates a group", %{account: account, subject: subject} do
      group = ActorsFixtures.create_group(account: account)

      attrs = ActorsFixtures.group_attrs()
      assert {:ok, group} = update_group(group, attrs, subject)
      assert group.name == attrs.name
    end

    test "updates group memberships", %{account: account, actor: actor, subject: subject} do
      group = ActorsFixtures.create_group(account: account, memberships: [%{actor_id: actor.id}])

      other_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)

      attrs =
        ActorsFixtures.group_attrs(
          memberships: [
            %{actor_id: other_actor.id}
          ]
        )

      assert {:ok, group} = update_group(group, attrs, subject)
      assert group.id
      assert group.name == attrs.name

      group = Repo.preload(group, :memberships)
      assert [%Actors.Membership{} = membership] = group.memberships
      assert membership.actor_id == other_actor.id
      assert membership.account_id == account.id
      assert membership.group_id == group.id
    end

    test "returns error when subject has no permission to manage groups", %{
      account: account,
      subject: subject
    } do
      group = ActorsFixtures.create_group(account: account)

      subject = AuthFixtures.remove_permissions(subject)

      assert update_group(group, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "delete_group/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns error on state conflict", %{account: account, subject: subject} do
      group = ActorsFixtures.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert delete_group(deleted, subject) == {:error, :not_found}
      assert delete_group(group, subject) == {:error, :not_found}
    end

    test "deletes groups", %{account: account, subject: subject} do
      group = ActorsFixtures.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at
    end

    test "returns error when subject has no permission to delete groups", %{
      subject: subject
    } do
      group = ActorsFixtures.create_group()

      subject = AuthFixtures.remove_permissions(subject)

      assert delete_group(group, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "fetch_count_by_type/0" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

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
      assert fetch_count_by_type(:account_admin_user, subject) == 1
      assert fetch_count_by_type(:account_user, subject) == 0

      ActorsFixtures.create_actor(type: :account_admin_user)
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      assert {:ok, _actor} = delete_actor(actor, subject)
      assert fetch_count_by_type(:account_admin_user, subject) == 1
      assert fetch_count_by_type(:account_user, subject) == 0

      ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      assert fetch_count_by_type(:account_admin_user, subject) == 2
      assert fetch_count_by_type(:account_user, subject) == 0

      ActorsFixtures.create_actor(type: :account_user)
      ActorsFixtures.create_actor(type: :account_user, account: account)
      assert fetch_count_by_type(:account_admin_user, subject) == 2
      assert fetch_count_by_type(:account_user, subject) == 1

      for _ <- 1..5, do: ActorsFixtures.create_actor(type: :account_user, account: account)
      assert fetch_count_by_type(:account_admin_user, subject) == 2
      assert fetch_count_by_type(:account_user, subject) == 6
    end

    test "returns error when subject can not view actors", %{subject: subject} do
      subject = AuthFixtures.remove_permissions(subject)

      assert fetch_count_by_type(:foo, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "fetch_actor_by_id/2" do
    test "returns error when actor is not found" do
      subject = AuthFixtures.create_subject()
      assert fetch_actor_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUID" do
      subject = AuthFixtures.create_subject()
      assert fetch_actor_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns own actor" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert {:ok, returned_actor} = fetch_actor_by_id(actor.id, subject)
      assert returned_actor.id == actor.id
    end

    test "returns non own actor" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      actor = ActorsFixtures.create_actor(account: account)

      assert {:ok, returned_actor} = fetch_actor_by_id(actor.id, subject)
      assert returned_actor.id == actor.id
    end

    test "returns error when actor is in another account" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      actor = ActorsFixtures.create_actor()

      assert fetch_actor_by_id(actor.id, subject) == {:error, :not_found}
    end

    test "returns error when subject can not view actors" do
      subject = AuthFixtures.create_subject()
      subject = AuthFixtures.remove_permissions(subject)

      assert fetch_actor_by_id("foo", subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
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
      actor = ActorsFixtures.create_actor(type: :account_admin_user)
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
      actor = ActorsFixtures.create_actor(type: :account_admin_user)
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
          context: nil,
          expires_at: nil,
          permissions: MapSet.new()
        }
        |> AuthFixtures.set_permissions([
          Actors.Authorizer.manage_actors_permission()
        ])

      assert list_actors(subject) == {:ok, []}
      assert list_actors(subject, hydrate: []) == {:ok, []}
    end

    test "returns list of actors in all types" do
      account = AccountsFixtures.create_account()
      actor1 = ActorsFixtures.create_actor(account: account, type: :account_admin_user)
      actor2 = ActorsFixtures.create_actor(account: account, type: :account_user)
      ActorsFixtures.create_actor(type: :account_user)

      identity1 = AuthFixtures.create_identity(account: account, actor: actor1)
      subject = AuthFixtures.create_subject(identity1)

      assert {:ok, actors} = list_actors(subject)
      assert length(actors) == 2
      assert Enum.sort(Enum.map(actors, & &1.id)) == Enum.sort([actor1.id, actor2.id])
    end

    test "returns error when subject can not view actors" do
      subject = AuthFixtures.create_subject()
      subject = AuthFixtures.remove_permissions(subject)

      assert list_actors(subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "create_actor/4" do
    setup do
      Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      provider_identifier = AuthFixtures.random_provider_identifier(provider)

      %{
        account: account,
        provider: provider,
        provider_identifier: provider_identifier
      }
    end

    test "returns changeset error when required attrs are missing", %{
      provider: provider,
      provider_identifier: provider_identifier
    } do
      assert {:error, changeset} = create_actor(provider, provider_identifier, %{})
      refute changeset.valid?

      assert errors_on(changeset) == %{
               type: ["can't be blank"],
               name: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{
      provider: provider,
      provider_identifier: provider_identifier
    } do
      attrs = ActorsFixtures.actor_attrs(type: :foo)

      assert {:error, changeset} = create_actor(provider, provider_identifier, attrs)
      refute changeset.valid?

      assert errors_on(changeset) == %{
               type: ["is invalid"]
             }
    end

    test "returns error on duplicate provider_identifier", %{
      provider: provider
    } do
      provider_identifier = AuthFixtures.random_provider_identifier(provider)
      attrs = ActorsFixtures.actor_attrs()
      assert {:ok, _actor} = create_actor(provider, provider_identifier, attrs)
      assert {:error, changeset} = create_actor(provider, provider_identifier, attrs)
      assert errors_on(changeset) == %{provider_identifier: ["has already been taken"]}
    end

    test "creates an actor in given type", %{
      provider: provider
    } do
      for type <- [:account_user, :account_admin_user, :service_account] do
        attrs = ActorsFixtures.actor_attrs(type: type)
        provider_identifier = AuthFixtures.random_provider_identifier(provider)
        assert {:ok, actor} = create_actor(provider, provider_identifier, attrs)
        assert actor.type == type
      end
    end

    test "creates an actor and identity", %{
      provider: provider,
      provider_identifier: provider_identifier
    } do
      attrs = ActorsFixtures.actor_attrs()

      assert {:ok, actor} = create_actor(provider, provider_identifier, attrs)

      assert actor.type == attrs.type
      assert actor.type == attrs.type
      assert is_nil(actor.disabled_at)
      assert is_nil(actor.deleted_at)

      assert identity = Repo.one(Domain.Auth.Identity)
      assert identity.provider_id == provider.id
      assert identity.provider_identifier == provider_identifier
      assert identity.actor_id == actor.id
      assert identity.account_id == provider.account_id

      assert %{"sign_in_token_created_at" => _, "sign_in_token_hash" => _} =
               identity.provider_state

      assert identity.provider_virtual_state == nil

      assert is_nil(identity.deleted_at)
    end
  end

  describe "create_actor/5" do
    setup do
      Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      provider_identifier = AuthFixtures.random_provider_identifier(provider)

      %{
        account: account,
        provider: provider,
        provider_identifier: provider_identifier
      }
    end

    test "returns error when subject can not create actors", %{
      account: account,
      provider: provider,
      provider_identifier: provider_identifier
    } do
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)

      subject =
        AuthFixtures.create_identity(account: account, actor: actor)
        |> AuthFixtures.create_subject()
        |> AuthFixtures.remove_permissions()

      assert create_actor(provider, provider_identifier, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end

    test "returns error when subject tries to create an account in another account", %{
      provider: provider,
      provider_identifier: provider_identifier
    } do
      subject = AuthFixtures.create_subject()
      assert create_actor(provider, provider_identifier, %{}, subject) == {:error, :unauthorized}
    end

    test "returns error when subject is trying to create an actor with a privilege escalation", %{
      account: account,
      provider: provider,
      provider_identifier: provider_identifier
    } do
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)

      subject =
        AuthFixtures.create_identity(account: account, actor: actor)
        |> AuthFixtures.create_subject()

      admin_permissions = subject.permissions
      required_permissions = [Actors.Authorizer.manage_actors_permission()]

      subject =
        subject
        |> AuthFixtures.remove_permissions()
        |> AuthFixtures.set_permissions(required_permissions)

      missing_permissions =
        MapSet.difference(admin_permissions, MapSet.new(required_permissions))
        |> MapSet.to_list()

      attrs = %{type: :account_admin_user, name: "John Smith"}

      assert create_actor(provider, provider_identifier, attrs, subject) ==
               {:error, {:unauthorized, privilege_escalation: missing_permissions}}

      attrs = %{"type" => "account_admin_user", "name" => "John Smith"}

      assert create_actor(provider, provider_identifier, attrs, subject) ==
               {:error, {:unauthorized, privilege_escalation: missing_permissions}}
    end
  end

  describe "change_actor_type/3" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      %{
        account: account,
        actor: actor,
        subject: subject
      }
    end

    test "allows admin to change other actors type", %{account: account, subject: subject} do
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      assert {:ok, %{type: :account_user}} = change_actor_type(actor, :account_user, subject)

      assert {:ok, %{type: :account_admin_user}} =
               change_actor_type(actor, :account_admin_user, subject)

      actor = ActorsFixtures.create_actor(type: :account_user, account: account)
      assert {:ok, %{type: :account_user}} = change_actor_type(actor, :account_user, subject)

      assert {:ok, %{type: :account_admin_user}} =
               change_actor_type(actor, :account_admin_user, subject)
    end

    test "returns error when subject can not manage types", %{account: account} do
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)

      subject =
        AuthFixtures.create_identity(account: account, actor: actor)
        |> AuthFixtures.create_subject()
        |> AuthFixtures.remove_permissions()

      assert change_actor_type(actor, :foo, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "disable_actor/2" do
    test "disables a given actor" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert {:ok, actor} = disable_actor(actor, subject)
      assert actor.disabled_at

      assert actor = Repo.get(Actors.Actor, actor.id)
      assert actor.disabled_at

      assert other_actor = Repo.get(Actors.Actor, other_actor.id)
      assert is_nil(other_actor.disabled_at)
    end

    test "returns error when trying to disable the last admin actor" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(account: account, type: :account_admin_user)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert disable_actor(actor, subject) == {:error, :cant_disable_the_last_admin}
    end

    test "last admin check ignores admins in other accounts" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      ActorsFixtures.create_actor(type: :account_admin_user)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert disable_actor(actor, subject) == {:error, :cant_disable_the_last_admin}
    end

    test "last admin check ignores disabled admins" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)
      {:ok, _other_actor} = disable_actor(other_actor, subject)

      assert disable_actor(actor, subject) == {:error, :cant_disable_the_last_admin}
    end

    test "returns error when trying to disable the last admin actor using a race condition" do
      for _ <- 0..50 do
        test_pid = self()

        Task.async(fn ->
          allow_child_sandbox_access(test_pid)

          Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

          account = AccountsFixtures.create_account()
          provider = AuthFixtures.create_email_provider(account: account)

          actor_one =
            ActorsFixtures.create_actor(
              type: :account_admin_user,
              account: account,
              provider: provider
            )

          actor_two =
            ActorsFixtures.create_actor(
              type: :account_admin_user,
              account: account,
              provider: provider
            )

          identity_one =
            AuthFixtures.create_identity(
              account: account,
              actor: actor_one,
              provider: provider
            )

          identity_two =
            AuthFixtures.create_identity(
              account: account,
              actor: actor_two,
              provider: provider
            )

          subject_one = AuthFixtures.create_subject(identity_one)
          subject_two = AuthFixtures.create_subject(identity_two)

          for {actor, subject} <- [{actor_two, subject_one}, {actor_one, subject_two}] do
            Task.async(fn ->
              allow_child_sandbox_access(test_pid)
              disable_actor(actor, subject)
            end)
          end
          |> Task.await_many()

          queryable =
            Actors.Actor.Query.by_account_id(account.id)
            |> Actors.Actor.Query.not_disabled()

          assert Repo.aggregate(queryable, :count) == 1
        end)
      end
      |> Task.await_many()
    end

    test "does not do anything when an actor is disabled twice" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert {:ok, _actor} = disable_actor(other_actor, subject)
      assert {:ok, other_actor} = disable_actor(other_actor, subject)
      assert {:ok, _actor} = disable_actor(other_actor, subject)
    end

    test "does not allow to disable actors in other accounts" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert disable_actor(other_actor, subject) == {:error, :not_found}
    end

    test "returns error when subject can not disable actors" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)

      subject =
        AuthFixtures.create_identity(account: account, actor: actor)
        |> AuthFixtures.create_subject()
        |> AuthFixtures.remove_permissions()

      assert disable_actor(actor, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "enable_actor/2" do
    test "enables a given actor" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      {:ok, actor} = disable_actor(actor, subject)

      assert {:ok, actor} = enable_actor(actor, subject)
      assert actor.disabled_at

      assert actor = Repo.get(Actors.Actor, actor.id)
      assert actor.disabled_at

      assert other_actor = Repo.get(Actors.Actor, other_actor.id)
      assert is_nil(other_actor.disabled_at)
    end

    test "does not do anything when an actor is already enabled" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      {:ok, other_actor} = disable_actor(other_actor, subject)

      assert {:ok, _actor} = enable_actor(other_actor, subject)
      assert {:ok, other_actor} = enable_actor(other_actor, subject)
      assert {:ok, _actor} = enable_actor(other_actor, subject)
    end

    test "does not allow to enable actors in other accounts" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert enable_actor(other_actor, subject) == {:error, :not_found}
    end

    test "returns error when subject can not enable actors" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)

      subject =
        AuthFixtures.create_identity(account: account, actor: actor)
        |> AuthFixtures.create_subject()
        |> AuthFixtures.remove_permissions()

      assert enable_actor(actor, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  describe "delete_actor/2" do
    test "deletes a given actor" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert {:ok, actor} = delete_actor(actor, subject)
      assert actor.deleted_at

      assert actor = Repo.get(Actors.Actor, actor.id)
      assert actor.deleted_at

      assert other_actor = Repo.get(Actors.Actor, other_actor.id)
      assert is_nil(other_actor.deleted_at)
    end

    test "returns error when trying to delete the last admin actor" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert delete_actor(actor, subject) == {:error, :cant_delete_the_last_admin}
    end

    test "last admin check ignores admins in other accounts" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      ActorsFixtures.create_actor(type: :account_admin_user)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert delete_actor(actor, subject) == {:error, :cant_delete_the_last_admin}
    end

    test "last admin check ignores disabled admins" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)
      {:ok, _other_actor} = disable_actor(other_actor, subject)

      assert delete_actor(actor, subject) == {:error, :cant_delete_the_last_admin}
    end

    test "returns error when trying to delete the last admin actor using a race condition" do
      for _ <- 0..50 do
        test_pid = self()

        Task.async(fn ->
          allow_child_sandbox_access(test_pid)

          Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

          account = AccountsFixtures.create_account()
          provider = AuthFixtures.create_email_provider(account: account)

          actor_one =
            ActorsFixtures.create_actor(
              type: :account_admin_user,
              account: account,
              provider: provider
            )

          actor_two =
            ActorsFixtures.create_actor(
              type: :account_admin_user,
              account: account,
              provider: provider
            )

          identity_one =
            AuthFixtures.create_identity(
              account: account,
              actor: actor_one,
              provider: provider
            )

          identity_two =
            AuthFixtures.create_identity(
              account: account,
              actor: actor_two,
              provider: provider
            )

          subject_one = AuthFixtures.create_subject(identity_one)
          subject_two = AuthFixtures.create_subject(identity_two)

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

    test "does not allow to delete an actor twice" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert {:ok, _actor} = delete_actor(other_actor, subject)
      assert delete_actor(other_actor, subject) == {:error, :not_found}
    end

    test "does not allow to delete actors in other accounts" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      other_actor = ActorsFixtures.create_actor(type: :account_admin_user)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert delete_actor(other_actor, subject) == {:error, :not_found}
    end

    test "returns error when subject can not delete actors" do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)

      subject =
        AuthFixtures.create_identity(account: account, actor: actor)
        |> AuthFixtures.create_subject()
        |> AuthFixtures.remove_permissions()

      assert delete_actor(actor, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Actors.Authorizer.manage_actors_permission()]]}}
    end
  end

  defp allow_child_sandbox_access(parent_pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Repo, parent_pid, self())
    # Allow is async call we need to break current process execution
    # to allow sandbox to be enabled
    :timer.sleep(10)
  end
end
