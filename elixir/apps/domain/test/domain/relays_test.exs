defmodule Domain.RelaysTest do
  use Domain.DataCase, async: true
  import Domain.Relays
  alias Domain.Relays

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

  describe "fetch_group_by_id/2" do
    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_group_by_id("foo", subject) == {:error, :not_found}
    end

    test "does not return groups from other accounts", %{
      subject: subject
    } do
      group = Fixtures.Relays.create_group()
      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "returns deleted groups", %{
      account: account,
      subject: subject
    } do
      group =
        Fixtures.Relays.create_group(account: account)
        |> Fixtures.Relays.delete_group()

      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group by id", %{account: account, subject: subject} do
      group = Fixtures.Relays.create_group(account: account)
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns global group by id", %{
      subject: subject
    } do
      group = Fixtures.Relays.create_global_group()
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Relays.create_group(account: account)
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
      Fixtures.Relays.create_group()
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list deleted groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Relays.create_group(account: account)
      |> Fixtures.Relays.delete_group()

      assert list_groups(subject) == {:ok, []}
    end

    test "returns all groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Relays.create_group(account: account)
      Fixtures.Relays.create_group(account: account)
      Fixtures.Relays.create_group()

      assert {:ok, groups} = list_groups(subject)
      assert length(groups) == 2
    end

    test "returns global groups", %{subject: subject} do
      Fixtures.Relays.create_global_group()

      assert {:ok, [_group]} = list_groups(subject)
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

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

      Fixtures.Relays.create_group(account: account, name: "foo")
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
      subject = Fixtures.Auth.remove_permissions(subject)

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

      Fixtures.Relays.create_global_group(name: "foo")
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
      group = Fixtures.Relays.create_group()

      group_attrs =
        Fixtures.Relays.group_attrs()
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
      group = Fixtures.Relays.create_group()
      attrs = %{name: nil}

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      group = Fixtures.Relays.create_group(account: account)

      attrs = %{
        name: String.duplicate("A", 65)
      }

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"]
             }

      Fixtures.Relays.create_group(account: account, name: "foo")
      attrs = %{name: "foo"}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "updates a group", %{account: account, subject: subject} do
      group = Fixtures.Relays.create_group(account: account)

      attrs = %{
        name: "foo"
      }

      assert {:ok, group} = update_group(group, attrs, subject)
      assert group.name == "foo"
    end

    test "does not allow updating global group", %{subject: subject} do
      group = Fixtures.Relays.create_global_group()
      attrs = %{name: "foo"}
      assert update_group(group, attrs, subject) == {:error, :unauthorized}
    end

    test "returns error when subject has no permission to manage groups", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Relays.create_group(account: account)

      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_group(group, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "delete_group/2" do
    test "returns error on state conflict", %{account: account, subject: subject} do
      group = Fixtures.Relays.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert delete_group(deleted, subject) == {:error, :not_found}
      assert delete_group(group, subject) == {:error, :not_found}
    end

    test "deletes groups", %{account: account, subject: subject} do
      group = Fixtures.Relays.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at
    end

    test "does not allow deleting global group", %{subject: subject} do
      group = Fixtures.Relays.create_global_group()
      assert delete_group(group, subject) == {:error, :unauthorized}
    end

    test "deletes all tokens when group is deleted", %{account: account, subject: subject} do
      group = Fixtures.Relays.create_group(account: account)
      Fixtures.Relays.create_token(group: group)
      Fixtures.Relays.create_token(group: [account: account])

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
      group = Fixtures.Relays.create_group()

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_group(group, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "use_token_by_id_and_secret/2" do
    test "returns token when secret is valid" do
      token = Fixtures.Relays.create_token()
      assert {:ok, token} = use_token_by_id_and_secret(token.id, token.value)
      assert is_nil(token.value)
      # TODO: While we don't have token rotation implemented, the tokens are all multi-use
      # assert is_nil(token.hash)
      # refute is_nil(token.deleted_at)
    end

    # TODO: While we don't have token rotation implemented, the tokens are all multi-use
    # test "returns error when secret was already used" do
    #   token = Fixtures.Relays.create_token()

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
      token = Fixtures.Relays.create_token()
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
      relay = Fixtures.Relays.create_relay()
      assert fetch_relay_by_id(relay.id, subject) == {:error, :not_found}
    end

    test "returns deleted relays", %{
      account: account,
      subject: subject
    } do
      relay =
        Fixtures.Relays.create_relay(account: account)
        |> Fixtures.Relays.delete_relay()

      assert {:ok, _relay} = fetch_relay_by_id(relay.id, subject)
    end

    test "returns relay by id", %{account: account, subject: subject} do
      relay = Fixtures.Relays.create_relay(account: account)
      assert fetch_relay_by_id(relay.id, subject) == {:ok, relay}
    end

    test "returns relay that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      relay = Fixtures.Relays.create_relay(account: account)
      assert fetch_relay_by_id(relay.id, subject) == {:ok, relay}
    end

    test "returns error when relay does not exist", %{subject: subject} do
      assert fetch_relay_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view relays", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

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
      Fixtures.Relays.create_relay()
      |> Fixtures.Relays.delete_relay()

      assert list_relays(subject) == {:ok, []}
    end

    test "returns all relays", %{
      account: account,
      subject: subject
    } do
      Fixtures.Relays.create_relay(account: account)
      Fixtures.Relays.create_relay(account: account)
      Fixtures.Relays.create_relay()

      group = Fixtures.Relays.create_global_group()
      relay = Fixtures.Relays.create_relay(group: group)

      assert {:ok, relays} = list_relays(subject)
      assert length(relays) == 3
      refute Enum.any?(relays, & &1.online?)

      :ok = connect_relay(relay, Ecto.UUID.generate())
      assert {:ok, relays} = list_relays(subject)
      assert length(relays) == 3
      assert Enum.any?(relays, & &1.online?)
    end

    test "returns error when subject has no permission to manage relays", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_relays(subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "list_connected_relays_for_resource/2" do
    test "returns empty list when there are no managed relays online", %{account: account} do
      resource = Fixtures.Resources.create_resource(account: account)
      group = Fixtures.Relays.create_global_group()

      Fixtures.Relays.create_relay(group: group)

      assert list_connected_relays_for_resource(resource, :managed) == {:ok, []}
    end

    test "returns empty list when there are no self-hosted relays online", %{account: account} do
      resource = Fixtures.Resources.create_resource(account: account)

      Fixtures.Relays.create_relay(account: account)

      Fixtures.Relays.create_relay(account: account)
      |> Fixtures.Relays.delete_relay()

      assert list_connected_relays_for_resource(resource, :self_hosted) == {:ok, []}
    end

    test "returns list of connected account relays", %{account: account} do
      resource = Fixtures.Resources.create_resource(account: account)
      relay1 = Fixtures.Relays.create_relay(account: account)
      relay2 = Fixtures.Relays.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()

      assert connect_relay(relay1, stamp_secret) == :ok
      assert connect_relay(relay2, stamp_secret) == :ok

      assert {:ok, connected_relays} = list_connected_relays_for_resource(resource, :self_hosted)

      assert Enum.all?(connected_relays, &(&1.stamp_secret == stamp_secret))
      assert Enum.sort(Enum.map(connected_relays, & &1.id)) == Enum.sort([relay1.id, relay2.id])
    end

    test "returns list of connected global relays", %{account: account} do
      resource = Fixtures.Resources.create_resource(account: account)
      group = Fixtures.Relays.create_global_group()
      relay = Fixtures.Relays.create_relay(group: group)
      stamp_secret = Ecto.UUID.generate()

      assert connect_relay(relay, stamp_secret) == :ok

      assert {:ok, [connected_relay]} = list_connected_relays_for_resource(resource, :managed)

      assert connected_relay.id == relay.id
      assert connected_relay.stamp_secret == stamp_secret
    end
  end

  describe "generate_username_and_password/1" do
    test "returns username and password", %{account: account} do
      relay = Fixtures.Relays.create_relay(account: account)
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
      token = Fixtures.Relays.create_token(account: context.account)

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
        last_seen_remote_ip: -1,
        last_seen_remote_ip_location_region: -1,
        last_seen_remote_ip_location_city: -1,
        last_seen_remote_ip_location_lat: :x,
        last_seen_remote_ip_location_lon: :x,
        port: -1
      }

      assert {:error, changeset} = upsert_relay(token, attrs)

      assert errors_on(changeset) == %{
               ipv4: ["one of these fields must be present: ipv4, ipv6", "is invalid"],
               ipv6: ["one of these fields must be present: ipv4, ipv6", "is invalid"],
               last_seen_user_agent: ["is invalid"],
               last_seen_remote_ip: ["is invalid"],
               last_seen_remote_ip_location_region: ["is invalid"],
               last_seen_remote_ip_location_city: ["is invalid"],
               last_seen_remote_ip_location_lat: ["is invalid"],
               last_seen_remote_ip_location_lon: ["is invalid"],
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
        Fixtures.Relays.relay_attrs()
        |> Map.delete(:name)

      assert {:ok, relay} = upsert_relay(token, attrs)

      assert relay.token_id == token.id
      assert relay.group_id == token.group_id

      assert relay.ipv4.address == attrs.ipv4
      assert relay.ipv6.address == attrs.ipv6

      assert relay.last_seen_remote_ip.address == attrs.last_seen_remote_ip

      assert relay.last_seen_remote_ip_location_region ==
               attrs.last_seen_remote_ip_location_region

      assert relay.last_seen_remote_ip_location_city == attrs.last_seen_remote_ip_location_city
      assert relay.last_seen_remote_ip_location_lat == attrs.last_seen_remote_ip_location_lat
      assert relay.last_seen_remote_ip_location_lon == attrs.last_seen_remote_ip_location_lon

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
        Fixtures.Relays.relay_attrs()
        |> Map.drop([:name, :ipv4])

      assert {:ok, _relay} = upsert_relay(token, attrs)
      assert {:ok, _relay} = upsert_relay(token, attrs)

      assert Repo.one(Relays.Relay)
    end

    test "updates ipv4 relay when it already exists", %{
      token: token
    } do
      relay = Fixtures.Relays.create_relay(token: token)

      attrs =
        Fixtures.Relays.relay_attrs(
          ipv4: relay.ipv4,
          last_seen_remote_ip: relay.ipv4,
          last_seen_user_agent: "iOS/12.5 (iPhone) connlib/0.7.411",
          last_seen_remote_ip_location_region: "Mexico",
          last_seen_remote_ip_location_city: "Merida",
          last_seen_remote_ip_location_lat: 7.7758,
          last_seen_remote_ip_location_lon: -2.4128
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

      assert updated_relay.last_seen_remote_ip_location_region ==
               attrs.last_seen_remote_ip_location_region

      assert updated_relay.last_seen_remote_ip_location_city ==
               attrs.last_seen_remote_ip_location_city

      assert updated_relay.last_seen_remote_ip_location_lat ==
               attrs.last_seen_remote_ip_location_lat

      assert updated_relay.last_seen_remote_ip_location_lon ==
               attrs.last_seen_remote_ip_location_lon

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end

    test "updates ipv6 relay when it already exists", %{
      token: token
    } do
      relay = Fixtures.Relays.create_relay(ipv4: nil, token: token)

      attrs =
        Fixtures.Relays.relay_attrs(
          ipv4: nil,
          ipv6: relay.ipv6,
          last_seen_remote_ip: relay.ipv6,
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

      assert updated_relay.ipv4 == nil
      assert updated_relay.ipv6.address == attrs.ipv6.address
      assert updated_relay.port == 3478

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end

    test "updates global relay when it already exists" do
      group = Fixtures.Relays.create_global_group()
      token = hd(group.tokens)
      relay = Fixtures.Relays.create_relay(group: group, token: token)

      attrs =
        Fixtures.Relays.relay_attrs(
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
      relay = Fixtures.Relays.create_relay(account: account)

      assert {:ok, deleted} = delete_relay(relay, subject)
      assert delete_relay(deleted, subject) == {:error, :not_found}
      assert delete_relay(relay, subject) == {:error, :not_found}
    end

    test "deletes relays", %{account: account, subject: subject} do
      relay = Fixtures.Relays.create_relay(account: account)

      assert {:ok, deleted} = delete_relay(relay, subject)
      assert deleted.deleted_at
    end

    test "returns error when subject has no permission to delete relays", %{
      subject: subject
    } do
      relay = Fixtures.Relays.create_relay()

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_relay(relay, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Relays.Authorizer.manage_relays_permission()]]}}
    end
  end

  describe "load_balance_relays/2" do
    test "returns empty list when there are no relays" do
      assert load_balance_relays({0, 0}, []) == []
    end

    test "returns random relays when there are no coordinates" do
      relay_1 = Fixtures.Relays.create_relay()
      relay_2 = Fixtures.Relays.create_relay()
      relay_3 = Fixtures.Relays.create_relay()

      assert relays = load_balance_relays({nil, nil}, [relay_1, relay_2, relay_3])
      assert length(relays) == 2
      assert Enum.all?(relays, &(&1.id in [relay_1.id, relay_2.id, relay_3.id]))
    end

    test "prioritizes relays with known location" do
      relay_1 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: 33.2029,
          last_seen_remote_ip_location_lon: -80.0131
        )

      relay_2 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: nil,
          last_seen_remote_ip_location_lon: nil
        )

      relays = [
        relay_1,
        relay_2
      ]

      assert [fetched_relay1, fetched_relay2] = load_balance_relays({32.2029, -80.0131}, relays)
      assert fetched_relay1.id == relay_1.id
      assert fetched_relay2.id == relay_2.id
    end

    test "returns at least two relays even if they are at the same location" do
      # Moncks Corner, South Carolina
      relay_us_east_1 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: 33.2029,
          last_seen_remote_ip_location_lon: -80.0131
        )

      relay_us_east_2 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: 33.2029,
          last_seen_remote_ip_location_lon: -80.0131
        )

      relays = [
        relay_us_east_1,
        relay_us_east_2
      ]

      assert [relay1] = load_balance_relays({32.2029, -80.0131}, relays)
      assert relay1.id in [relay_us_east_1.id, relay_us_east_2.id]
    end

    test "selects relays in two closest regions to a given location" do
      # Moncks Corner, South Carolina
      relay_us_east_1 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: 33.2029,
          last_seen_remote_ip_location_lon: -80.0131
        )

      relay_us_east_2 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: 33.2029,
          last_seen_remote_ip_location_lon: -80.0131
        )

      relay_us_east_3 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: 33.2029,
          last_seen_remote_ip_location_lon: -80.0131
        )

      # The Dalles, Oregon
      relay_us_west_1 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: 45.5946,
          last_seen_remote_ip_location_lon: -121.1787
        )

      relay_us_west_2 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: 45.5946,
          last_seen_remote_ip_location_lon: -121.1787
        )

      # Council Bluffs, Iowa
      relay_us_central_1 =
        Fixtures.Relays.create_relay(
          last_seen_remote_ip_location_lat: 41.2619,
          last_seen_remote_ip_location_lon: -95.8608
        )

      relays = [
        relay_us_east_1,
        relay_us_east_2,
        relay_us_east_3,
        relay_us_west_1,
        relay_us_west_2,
        relay_us_central_1
      ]

      # multiple attempts are used to increase chances that all relays in a group are randomly selected
      for _ <- 0..3 do
        assert [relay1, relay2] = load_balance_relays({32.2029, -80.0131}, relays)
        assert relay1.id in [relay_us_east_1.id, relay_us_east_2.id, relay_us_east_3.id]
        assert relay2.id == relay_us_central_1.id
      end

      for _ <- 0..2 do
        assert [relay1, relay2] = load_balance_relays({45.5946, -121.1787}, relays)
        assert relay1.id in [relay_us_west_1.id, relay_us_west_2.id]
        assert relay2.id == relay_us_central_1.id
      end

      assert [relay1, _relay2] = load_balance_relays({42.2619, -96.8608}, relays)
      assert relay1.id == relay_us_central_1.id
    end
  end

  describe "encode_token!/1" do
    test "returns encoded token" do
      token = Fixtures.Relays.create_token()
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
      token = Fixtures.Relays.create_token()
      encoded_token = encode_token!(token)
      assert {:ok, fetched_token} = authorize_relay(encoded_token)
      assert fetched_token.id == token.id
      assert is_nil(fetched_token.value)
    end

    test "returns error when secret is invalid" do
      assert authorize_relay(Ecto.UUID.generate()) == {:error, :invalid_token}
    end
  end

  describe "connect_relay/2" do
    test "does not allow duplicate presence", %{account: account} do
      relay = Fixtures.Relays.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()

      assert connect_relay(relay, stamp_secret) == :ok
      assert {:error, {:already_tracked, _pid, _topic, _key}} = connect_relay(relay, stamp_secret)
    end
  end
end
