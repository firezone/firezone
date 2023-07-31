defmodule Domain.RelaysTest do
  use Domain.DataCase, async: true
  import Domain.Relays
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures, ResourcesFixtures}
  alias Domain.RelaysFixtures
  alias Domain.Relays

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

  describe "fetch_group_by_id/2" do
    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_group_by_id("foo", subject) == {:error, :not_found}
    end

    test "does not return groups from other accounts", %{
      subject: subject
    } do
      group = RelaysFixtures.create_group()
      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "does not return deleted groups", %{
      account: account,
      subject: subject
    } do
      group =
        RelaysFixtures.create_group(account: account)
        |> RelaysFixtures.delete_group()

      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "returns group by id", %{account: account, subject: subject} do
      group = RelaysFixtures.create_group(account: account)
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns global group by id", %{
      subject: subject
    } do
      group = RelaysFixtures.create_global_group()
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      group = RelaysFixtures.create_group(account: account)
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
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "list_groups/1" do
    test "returns empty list when there are no groups", %{subject: subject} do
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list groups from other accounts", %{
      subject: subject
    } do
      RelaysFixtures.create_group()
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list deleted groups", %{
      account: account,
      subject: subject
    } do
      RelaysFixtures.create_group(account: account)
      |> RelaysFixtures.delete_group()

      assert list_groups(subject) == {:ok, []}
    end

    test "returns all groups", %{
      account: account,
      subject: subject
    } do
      RelaysFixtures.create_group(account: account)
      RelaysFixtures.create_group(account: account)
      RelaysFixtures.create_group()

      assert {:ok, groups} = list_groups(subject)
      assert length(groups) == 2
    end

    test "returns global groups", %{subject: subject} do
      RelaysFixtures.create_global_group()

      assert {:ok, [_group]} = list_groups(subject)
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

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

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      attrs = %{
        name: String.duplicate("A", 65)
      }

      assert {:error, changeset} = create_group(attrs, subject)

      assert errors_on(changeset) == %{
               tokens: ["can't be blank"],
               name: ["should be at most 64 character(s)"]
             }

      RelaysFixtures.create_group(account: account, name: "foo")
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

      assert group.created_by == :identity
      assert group.created_by_identity_id == subject.identity.id

      assert [%Relays.Token{} = token] = group.tokens
      assert token.created_by == :identity
      assert token.created_by_identity_id == subject.identity.id
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert create_group(%{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "create_global_group/1" do
    test "returns error on empty attrs" do
      assert {:error, changeset} = create_global_group(%{})
      assert errors_on(changeset) == %{tokens: ["can't be blank"]}
    end

    test "returns error on invalid attrs" do
      attrs = %{
        name: String.duplicate("A", 65)
      }

      assert {:error, changeset} = create_global_group(attrs)

      assert errors_on(changeset) == %{
               tokens: ["can't be blank"],
               name: ["should be at most 64 character(s)"]
             }

      RelaysFixtures.create_global_group(name: "foo")
      attrs = %{name: "foo", tokens: [%{}]}
      assert {:error, changeset} = create_global_group(attrs)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "creates a group" do
      attrs = %{
        name: "foo",
        tokens: [%{}]
      }

      assert {:ok, group} = create_global_group(attrs)
      assert group.id
      assert group.name == "foo"

      assert group.created_by == :system
      assert is_nil(group.created_by_identity_id)

      assert [%Relays.Token{} = token] = group.tokens
      assert token.created_by == :system
      assert is_nil(token.created_by_identity_id)
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

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      group = RelaysFixtures.create_group(account: account)

      attrs = %{
        name: String.duplicate("A", 65)
      }

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"]
             }

      RelaysFixtures.create_group(account: account, name: "foo")
      attrs = %{name: "foo"}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "updates a group", %{account: account, subject: subject} do
      group = RelaysFixtures.create_group(account: account)

      attrs = %{
        name: "foo"
      }

      assert {:ok, group} = update_group(group, attrs, subject)
      assert group.name == "foo"
    end

    test "does not allow updating global group", %{subject: subject} do
      group = RelaysFixtures.create_global_group()
      attrs = %{name: "foo"}
      assert update_group(group, attrs, subject) == {:error, :unauthorized}
    end

    test "returns error when subject has no permission to manage groups", %{
      account: account,
      subject: subject
    } do
      group = RelaysFixtures.create_group(account: account)

      subject = AuthFixtures.remove_permissions(subject)

      assert update_group(group, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "delete_group/2" do
    test "returns error on state conflict", %{account: account, subject: subject} do
      group = RelaysFixtures.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert delete_group(deleted, subject) == {:error, :not_found}
      assert delete_group(group, subject) == {:error, :not_found}
    end

    test "deletes groups", %{account: account, subject: subject} do
      group = RelaysFixtures.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at
    end

    test "does not allow deleting global group", %{subject: subject} do
      group = RelaysFixtures.create_global_group()
      assert delete_group(group, subject) == {:error, :unauthorized}
    end

    test "deletes all tokens when group is deleted", %{account: account, subject: subject} do
      group = RelaysFixtures.create_group(account: account)
      RelaysFixtures.create_token(group: group)
      RelaysFixtures.create_token(group: [account: account])

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

      subject = AuthFixtures.remove_permissions(subject)

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

    test "does not return relays from other accounts", %{
      subject: subject
    } do
      relay = RelaysFixtures.create_relay()
      assert fetch_relay_by_id(relay.id, subject) == {:error, :not_found}
    end

    test "does not return deleted relays", %{
      account: account,
      subject: subject
    } do
      relay =
        RelaysFixtures.create_relay(account: account)
        |> RelaysFixtures.delete_relay()

      assert fetch_relay_by_id(relay.id, subject) == {:error, :not_found}
    end

    test "returns relay by id", %{account: account, subject: subject} do
      relay = RelaysFixtures.create_relay(account: account)
      assert fetch_relay_by_id(relay.id, subject) == {:ok, relay}
    end

    test "returns relay that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      relay = RelaysFixtures.create_relay(account: account)
      assert fetch_relay_by_id(relay.id, subject) == {:ok, relay}
    end

    test "returns error when relay does not exist", %{subject: subject} do
      assert fetch_relay_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view relays", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

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
      account: account,
      subject: subject
    } do
      RelaysFixtures.create_relay(account: account)
      RelaysFixtures.create_relay(account: account)
      RelaysFixtures.create_relay()

      assert {:ok, relays} = list_relays(subject)
      assert length(relays) == 2
    end

    test "returns error when subject has no permission to manage relays", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert list_relays(subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "list_connected_relays_for_resource/1" do
    test "returns empty list when there are no online relays", %{account: account} do
      resource = ResourcesFixtures.create_resource(account: account)

      RelaysFixtures.create_relay(account: account)

      RelaysFixtures.create_relay(account: account)
      |> RelaysFixtures.delete_relay()

      assert list_connected_relays_for_resource(resource) == {:ok, []}
    end

    test "returns list of connected account relays", %{account: account} do
      resource = ResourcesFixtures.create_resource(account: account)
      relay = RelaysFixtures.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()

      assert connect_relay(relay, stamp_secret) == :ok

      assert {:ok, [connected_relay]} = list_connected_relays_for_resource(resource)

      assert connected_relay.id == relay.id
      assert connected_relay.stamp_secret == stamp_secret
    end

    test "returns list of connected global relays", %{account: account} do
      resource = ResourcesFixtures.create_resource(account: account)
      group = RelaysFixtures.create_global_group()
      relay = RelaysFixtures.create_relay(group: group)
      stamp_secret = Ecto.UUID.generate()

      assert connect_relay(relay, stamp_secret) == :ok

      assert {:ok, [connected_relay]} = list_connected_relays_for_resource(resource)

      assert connected_relay.id == relay.id
      assert connected_relay.stamp_secret == stamp_secret
    end
  end

  describe "generate_username_and_password/1" do
    test "returns username and password", %{account: account} do
      relay = RelaysFixtures.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()
      relay = %{relay | stamp_secret: stamp_secret}
      expires_at = DateTime.utc_now() |> DateTime.add(3, :second)

      assert %{username: username, password: password, expires_at: expires_at_unix} =
               generate_username_and_password(relay, expires_at)

      assert [username_expires_at_unix, username_salt] = String.split(username, ":", parts: 2)
      assert username_expires_at_unix == to_string(expires_at_unix)
      assert DateTime.from_unix!(expires_at_unix) == DateTime.truncate(expires_at, :second)

      expected_hash =
        :crypto.hash(:sha256, "#{expires_at_unix}:#{stamp_secret}:#{username_salt}")
        |> Base.encode64(padding: false, case: :lower)

      assert password == expected_hash
    end
  end

  describe "upsert_relay/3" do
    setup context do
      token = RelaysFixtures.create_token(account: context.account)

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
        last_seen_remote_ip: {256, 0, 0, 0},
        port: -1
      }

      assert {:error, changeset} = upsert_relay(token, attrs)

      assert errors_on(changeset) == %{
               ipv4: ["one of these fields must be present: ipv4, ipv6", "is invalid"],
               ipv6: ["one of these fields must be present: ipv4, ipv6", "is invalid"],
               last_seen_user_agent: ["is invalid"],
               port: ["must be greater than or equal to 1"]
             }

      attrs = %{port: 100_000}
      assert {:error, changeset} = upsert_relay(token, attrs)
      assert "must be less than or equal to 65535" in errors_on(changeset).port
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
      assert relay.port == 3478

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end

    test "allows creating ipv6-only relays", %{
      token: token
    } do
      attrs =
        RelaysFixtures.relay_attrs()
        |> Map.drop([:name, :ipv4])

      assert {:ok, _relay} = upsert_relay(token, attrs)
      assert {:ok, _relay} = upsert_relay(token, attrs)

      assert Repo.one(Relays.Relay)
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
      assert updated_relay.port == 3478

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end
  end

  describe "delete_relay/2" do
    test "returns error on state conflict", %{account: account, subject: subject} do
      relay = RelaysFixtures.create_relay(account: account)

      assert {:ok, deleted} = delete_relay(relay, subject)
      assert delete_relay(deleted, subject) == {:error, :not_found}
      assert delete_relay(relay, subject) == {:error, :not_found}
    end

    test "deletes relays", %{account: account, subject: subject} do
      relay = RelaysFixtures.create_relay(account: account)

      assert {:ok, deleted} = delete_relay(relay, subject)
      assert deleted.deleted_at
    end

    test "returns error when subject has no permission to delete relays", %{
      subject: subject
    } do
      relay = RelaysFixtures.create_relay()

      subject = AuthFixtures.remove_permissions(subject)

      assert delete_relay(relay, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "encode_token!/1" do
    test "returns encoded token" do
      token = RelaysFixtures.create_token()
      assert encrypted_secret = encode_token!(token)

      config = Application.fetch_env!(:domain, Domain.Relays)
      key_base = Keyword.fetch!(config, :key_base)
      salt = Keyword.fetch!(config, :salt)

      assert Plug.Crypto.verify(key_base, salt, encrypted_secret) ==
               {:ok, {token.id, token.value}}
    end
  end

  describe "authorize_relay/1" do
    test "returns token when encoded secret is valid" do
      token = RelaysFixtures.create_token()
      encoded_token = encode_token!(token)
      assert {:ok, fetched_token} = authorize_relay(encoded_token)
      assert fetched_token.id == token.id
      assert is_nil(fetched_token.value)
    end

    test "returns error when secret is invalid" do
      assert authorize_relay(Ecto.UUID.generate()) == {:error, :invalid_token}
    end
  end
end
