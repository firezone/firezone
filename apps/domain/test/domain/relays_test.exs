defmodule Domain.RelaysTest do
  use Domain.DataCase, async: true
  import Domain.Relays
  alias Domain.{UsersFixtures, SubjectFixtures, RelaysFixtures}
  alias Domain.Relays

  setup do
    user = UsersFixtures.create_user_with_role(:admin)
    subject = SubjectFixtures.create_subject(user)

    %{
      user: user,
      subject: subject
    }
  end

  describe "fetch_group_by_id/2" do
    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_group_by_id("foo", subject) == {:error, :not_found}
    end

    test "does not return deleted groups", %{
      subject: subject
    } do
      group =
        RelaysFixtures.create_group()
        |> RelaysFixtures.delete_group()

      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "returns group by id", %{subject: subject} do
      group = RelaysFixtures.create_group()
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group that belongs to another user", %{
      subject: subject
    } do
      group = RelaysFixtures.create_group()
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
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_group_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "list_groups/1" do
    test "returns empty list when there are no groups", %{subject: subject} do
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list deleted groups", %{
      subject: subject
    } do
      RelaysFixtures.create_group()
      |> RelaysFixtures.delete_group()

      assert list_groups(subject) == {:ok, []}
    end

    test "returns all groups", %{
      subject: subject
    } do
      RelaysFixtures.create_group()
      RelaysFixtures.create_group()

      assert {:ok, groups} = list_groups(subject)
      assert length(groups) == 2
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_groups(subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "new_group/0" do
    test "returns group changeset" do
      assert %Ecto.Changeset{data: %Relays.Group{}, changes: changes} = new_group()
      assert Map.has_key?(changes, :name)
      assert Enum.count(changes) == 1
    end
  end

  describe "create_group/2" do
    test "returns error on empty attrs", %{subject: subject} do
      assert {:error, changeset} = create_group(%{}, subject)
      assert errors_on(changeset) == %{tokens: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{subject: subject} do
      attrs = %{
        name: String.duplicate("A", 65)
      }

      assert {:error, changeset} = create_group(attrs, subject)

      assert errors_on(changeset) == %{
               tokens: ["can't be blank"],
               name: ["should be at most 64 character(s)"]
             }

      RelaysFixtures.create_group(name: "foo")
      attrs = %{name: "foo", tokens: [%{}]}
      assert {:error, changeset} = create_group(attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "creates a group", %{subject: subject} do
      attrs = %{
        name: "foo",
        tokens: [%{}]
      }

      assert {:ok, group} = create_group(attrs, subject)
      assert group.id
      assert group.name == "foo"
      assert [%Relays.Token{}] = group.tokens
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert create_group(%{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "change_group/1" do
    test "returns changeset with given changes" do
      group = RelaysFixtures.create_group()

      group_attrs =
        RelaysFixtures.group_attrs()
        |> Map.delete(:tokens)

      assert changeset = change_group(group, group_attrs)
      assert changeset.valid?
      assert changeset.changes == %{name: group_attrs.name}
    end
  end

  describe "update_group/3" do
    test "does not allow to reset required fields to empty values", %{
      subject: subject
    } do
      group = RelaysFixtures.create_group()
      attrs = %{name: nil}

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{subject: subject} do
      group = RelaysFixtures.create_group()

      attrs = %{
        name: String.duplicate("A", 65)
      }

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"]
             }

      RelaysFixtures.create_group(name: "foo")
      attrs = %{name: "foo"}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "updates a group", %{subject: subject} do
      group = RelaysFixtures.create_group()

      attrs = %{
        name: "foo"
      }

      assert {:ok, group} = update_group(group, attrs, subject)
      assert group.name == "foo"
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      group = RelaysFixtures.create_group()

      subject = SubjectFixtures.remove_permissions(subject)

      assert update_group(group, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "delete_group/2" do
    test "returns error on state conflict", %{subject: subject} do
      group = RelaysFixtures.create_group()

      assert {:ok, deleted} = delete_group(group, subject)
      assert delete_group(deleted, subject) == {:error, :not_found}
      assert delete_group(group, subject) == {:error, :not_found}
    end

    test "deletes groups", %{subject: subject} do
      group = RelaysFixtures.create_group()

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at
    end

    test "deletes all tokens when group is deleted", %{subject: subject} do
      group = RelaysFixtures.create_group()
      RelaysFixtures.create_token(group: group)
      RelaysFixtures.create_token()

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at

      tokens =
        Relays.Token
        |> Repo.all()
        |> Enum.filter(fn token -> token.group_id == group.id end)

      assert Enum.all?(tokens, & &1.deleted_at)
    end

    test "returns error when subject has no permission to delete groups", %{
      subject: subject
    } do
      group = RelaysFixtures.create_group()

      subject = SubjectFixtures.remove_permissions(subject)

      assert delete_group(group, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "use_token_by_id_and_secret/2" do
    test "returns token when secret is valid" do
      token = RelaysFixtures.create_token()
      assert {:ok, token} = use_token_by_id_and_secret(token.id, token.value)
      assert is_nil(token.value)
      # TODO: While we don't have token rotation implemented, the tokens are all multi-use
      # assert is_nil(token.hash)
      # refute is_nil(token.deleted_at)
    end

    # TODO: While we don't have token rotation implemented, the tokens are all multi-use
    # test "returns error when secret was already used" do
    #   token = RelaysFixtures.create_token()

    #   assert {:ok, _token} = use_token_by_id_and_secret(token.id, token.value)
    #   assert use_token_by_id_and_secret(token.id, token.value) == {:error, :not_found}
    # end

    test "returns error when id is invalid" do
      assert use_token_by_id_and_secret("foo", "bar") == {:error, :not_found}
    end

    test "returns error when id is not found" do
      assert use_token_by_id_and_secret(Ecto.UUID.generate(), "bar") == {:error, :not_found}
    end

    test "returns error when secret is invalid" do
      token = RelaysFixtures.create_token()
      assert use_token_by_id_and_secret(token.id, "bar") == {:error, :not_found}
    end
  end

  describe "fetch_relay_by_id/2" do
    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_relay_by_id("foo", subject) == {:error, :not_found}
    end

    test "does not return deleted relays", %{
      subject: subject
    } do
      relay =
        RelaysFixtures.create_relay()
        |> RelaysFixtures.delete_relay()

      assert fetch_relay_by_id(relay.id, subject) == {:error, :not_found}
    end

    test "returns relay by id", %{subject: subject} do
      relay = RelaysFixtures.create_relay()
      assert fetch_relay_by_id(relay.id, subject) == {:ok, relay}
    end

    test "returns relay that belongs to another user", %{
      subject: subject
    } do
      relay = RelaysFixtures.create_relay()
      assert fetch_relay_by_id(relay.id, subject) == {:ok, relay}
    end

    test "returns error when relay does not exist", %{subject: subject} do
      assert fetch_relay_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view relays", %{
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_relay_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "list_relays/1" do
    test "returns empty list when there are no relays", %{subject: subject} do
      assert list_relays(subject) == {:ok, []}
    end

    test "does not list deleted relays", %{
      subject: subject
    } do
      RelaysFixtures.create_relay()
      |> RelaysFixtures.delete_relay()

      assert list_relays(subject) == {:ok, []}
    end

    test "returns all relays", %{
      subject: subject
    } do
      RelaysFixtures.create_relay()
      RelaysFixtures.create_relay()

      assert {:ok, relays} = list_relays(subject)
      assert length(relays) == 2
    end

    test "returns error when subject has no permission to manage relays", %{
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_relays(subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "upsert_relay/3" do
    setup context do
      token = RelaysFixtures.create_token()

      context
      |> Map.put(:token, token)
      |> Map.put(:group, token.group)
    end

    test "returns errors on invalid attrs", %{
      token: token
    } do
      attrs = %{
        ipv4: "1.1.1.256",
        ipv6: "fd01::10000",
        last_seen_user_agent: "foo",
        last_seen_remote_ip: {256, 0, 0, 0}
      }

      assert {:error, changeset} = upsert_relay(token, attrs)

      assert errors_on(changeset) == %{
               ipv4: ["is invalid"],
               ipv6: ["is invalid"],
               last_seen_user_agent: ["is invalid"]
             }
    end

    test "allows creating relay with just required attributes", %{
      token: token
    } do
      attrs =
        RelaysFixtures.relay_attrs()
        |> Map.delete(:name)

      assert {:ok, relay} = upsert_relay(token, attrs)

      assert relay.token_id == token.id
      assert relay.group_id == token.group_id

      assert relay.ipv4.address == attrs.ipv4
      assert relay.ipv6.address == attrs.ipv6

      assert relay.last_seen_remote_ip.address == attrs.last_seen_remote_ip
      assert relay.last_seen_user_agent == attrs.last_seen_user_agent
      assert relay.last_seen_version == "0.7.412"
      assert relay.last_seen_at

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end

    test "updates relay when it already exists", %{
      token: token
    } do
      relay = RelaysFixtures.create_relay(token: token)

      attrs =
        RelaysFixtures.relay_attrs(
          ipv4: relay.ipv4,
          last_seen_remote_ip: relay.ipv4,
          last_seen_user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"
        )

      assert {:ok, updated_relay} = upsert_relay(token, attrs)

      assert Repo.aggregate(Relays.Relay, :count, :id) == 1

      assert updated_relay.last_seen_remote_ip.address == attrs.last_seen_remote_ip.address
      assert updated_relay.last_seen_user_agent == attrs.last_seen_user_agent
      assert updated_relay.last_seen_user_agent != relay.last_seen_user_agent
      assert updated_relay.last_seen_version == "0.7.411"
      assert updated_relay.last_seen_at
      assert updated_relay.last_seen_at != relay.last_seen_at

      assert updated_relay.token_id == token.id
      assert updated_relay.group_id == token.group_id

      assert updated_relay.ipv4 == relay.ipv4
      assert updated_relay.ipv6.address == attrs.ipv6
      assert updated_relay.ipv6 != relay.ipv6

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end
  end

  describe "delete_relay/2" do
    test "returns error on state conflict", %{subject: subject} do
      relay = RelaysFixtures.create_relay()

      assert {:ok, deleted} = delete_relay(relay, subject)
      assert delete_relay(deleted, subject) == {:error, :not_found}
      assert delete_relay(relay, subject) == {:error, :not_found}
    end

    test "deletes relays", %{subject: subject} do
      relay = RelaysFixtures.create_relay()

      assert {:ok, deleted} = delete_relay(relay, subject)
      assert deleted.deleted_at
    end

    test "returns error when subject has no permission to delete relays", %{
      subject: subject
    } do
      relay = RelaysFixtures.create_relay()

      subject = SubjectFixtures.remove_permissions(subject)

      assert delete_relay(relay, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end
end
