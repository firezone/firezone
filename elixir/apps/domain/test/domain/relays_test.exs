defmodule Domain.RelaysTest do
  use Domain.DataCase, async: true
  import Domain.Relays
  alias Domain.{Relays, Tokens}

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

  describe "fetch_group_by_id/3" do
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
                 reason: :missing_permissions,
                 missing_permissions: [Relays.Authorizer.manage_relays_permission()]}}
    end
  end

  describe "list_groups/2" do
    test "returns empty list when there are no groups", %{subject: subject} do
      assert {:ok, [], _metadata} = list_groups(subject)
    end

    test "does not list groups from other accounts", %{
      subject: subject
    } do
      Fixtures.Relays.create_group()
      assert {:ok, [], _metadata} = list_groups(subject)
    end

    test "does not list deleted groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Relays.create_group(account: account)
      |> Fixtures.Relays.delete_group()

      assert {:ok, [], _metadata} = list_groups(subject)
    end

    test "returns all groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Relays.create_group(account: account)
      Fixtures.Relays.create_group(account: account)
      Fixtures.Relays.create_group()

      assert {:ok, groups, _metadata} = list_groups(subject)
      assert length(groups) == 2
    end

    test "returns global groups", %{subject: subject} do
      Fixtures.Relays.create_global_group()

      assert {:ok, [_group], _metadata} = list_groups(subject)
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_groups(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Relays.Authorizer.manage_relays_permission()]}}
    end
  end

  describe "new_group/1" do
    test "returns group changeset" do
      assert %Ecto.Changeset{data: %Relays.Group{}, changes: changes} = new_group()
      assert Map.has_key?(changes, :name)
      assert Enum.count(changes) == 1
    end
  end

  describe "create_group/2" do
    test "returns group on empty attrs", %{subject: subject} do
      assert {:ok, _group} = create_group(%{}, subject)
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      attrs = %{
        name: String.duplicate("A", 65)
      }

      assert {:error, changeset} = create_group(attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"]
             }

      Fixtures.Relays.create_group(account: account, name: "foo")
      attrs = %{name: "foo"}
      assert {:error, changeset} = create_group(attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "creates a group", %{subject: subject} do
      attrs = %{name: Ecto.UUID.generate()}

      assert {:ok, group} = create_group(attrs, subject)
      assert group.id
      assert group.name == attrs.name

      assert group.created_by == :identity
      assert group.created_by_identity_id == subject.identity.id

      assert group.created_by_subject == %{
               "name" => subject.actor.name,
               "email" => subject.identity.email
             }
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_group(%{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Relays.Authorizer.manage_relays_permission()]}}
    end
  end

  describe "create_global_group/1" do
    test "returns group on empty attrs" do
      assert {:ok, _group} = create_global_group(%{})
    end

    test "returns error on invalid attrs" do
      attrs = %{
        name: String.duplicate("A", 65)
      }

      assert {:error, changeset} = create_global_group(attrs)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"]
             }

      name = Ecto.UUID.generate()
      Fixtures.Relays.create_global_group(name: name)
      attrs = %{name: name}
      assert {:error, changeset} = create_global_group(attrs)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "creates a group" do
      attrs = %{name: Ecto.UUID.generate()}

      assert {:ok, group} = create_global_group(attrs)
      assert group.id
      assert group.name == attrs.name

      assert group.created_by == :system
      assert is_nil(group.created_by_identity_id)
      assert group.created_by_subject == %{"name" => "System", "email" => nil}
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
                 reason: :missing_permissions,
                 missing_permissions: [Relays.Authorizer.manage_relays_permission()]}}
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
      Fixtures.Relays.create_token(account: account, group: group)
      Fixtures.Relays.create_token(account: account, group: [account: account])

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at

      tokens =
        Domain.Tokens.Token.Query.all()
        |> Domain.Tokens.Token.Query.by_relay_group_id(group.id)
        |> Repo.all()

      assert length(tokens) > 0
      assert Enum.all?(tokens, & &1.deleted_at)
    end

    test "deletes all relays when group is deleted", %{account: account, subject: subject} do
      group = Fixtures.Relays.create_group(account: account)
      Fixtures.Relays.create_relay(account: account, group: group)

      assert {:ok, _group} = delete_group(group, subject)

      relays =
        Domain.Relays.Relay.Query.all()
        |> Domain.Relays.Relay.Query.by_group_id(group.id)
        |> Repo.all()

      assert length(relays) > 0
      assert Enum.all?(relays, & &1.deleted_at)
    end

    test "broadcasts disconnect message to all connected relay sockets", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Relays.create_group(account: account)

      token1 = Fixtures.Relays.create_token(account: account, group: group)
      Domain.PubSub.subscribe(Tokens.socket_id(token1))

      token2 = Fixtures.Relays.create_token(account: account, group: group)
      Domain.PubSub.subscribe(Tokens.socket_id(token2))

      Fixtures.Relays.create_relay(account: account, group: group)

      assert {:ok, _group} = delete_group(group, subject)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "broadcasts disconnect message to all connected relays", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Relays.create_group(account: account)
      Fixtures.Relays.create_relay(account: account, group: group)
      token = Fixtures.Relays.create_token(account: account, group: group)

      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, _group} = delete_group(group, subject)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "returns error when subject has no permission to delete groups", %{
      subject: subject
    } do
      group = Fixtures.Relays.create_group()

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_group(group, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Relays.Authorizer.manage_relays_permission()]}}
    end
  end

  describe "create_token/2" do
    setup do
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      %{
        context: %Domain.Auth.Context{
          type: :relay_group,
          remote_ip: remote_ip,
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.4501,
          remote_ip_location_lon: 30.5234,
          user_agent: user_agent
        }
      }
    end

    test "returns valid token for a relay group", %{
      account: account,
      context: context,
      subject: subject
    } do
      group = Fixtures.Relays.create_group(account: account)

      assert {:ok, created_token, encoded_token} = create_token(group, %{}, subject)
      refute created_token.secret_nonce
      refute created_token.secret_fragment

      assert {:ok, fetched_group, fetched_token} = authenticate(encoded_token, context)
      assert fetched_group.id == group.id

      assert token = Repo.get_by(Tokens.Token, relay_group_id: fetched_group.id)
      assert token.id == fetched_token.id
      assert token.id == created_token.id
      assert token.type == :relay_group
      assert token.account_id == account.id
      assert token.relay_group_id == group.id
      assert token.created_by == :identity
      assert token.created_by_identity_id == subject.identity.id
      assert token.created_by_user_agent == subject.context.user_agent
      assert token.created_by_remote_ip.address == subject.context.remote_ip
      refute token.expires_at
    end

    test "returns valid token for a global relay group", %{
      context: context
    } do
      group = Fixtures.Relays.create_global_group()

      assert {:ok, token, encoded_token} = create_token(group, %{})

      assert token.type == :relay_group
      refute token.account_id
      assert token.relay_group_id == group.id
      assert token.created_by == :system
      refute token.created_by_identity_id
      refute token.created_by_user_agent
      refute token.created_by_remote_ip
      refute token.expires_at

      assert {:ok, fetched_group, fetched_token} = authenticate(encoded_token, context)
      assert fetched_group.id == group.id
      assert fetched_token.id == token.id
    end
  end

  describe "create_token/3" do
    setup do
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      %{
        context: %Domain.Auth.Context{
          type: :relay_group,
          remote_ip: remote_ip,
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.4501,
          remote_ip_location_lon: 30.5234,
          user_agent: user_agent
        }
      }
    end

    test "returns valid token for a given relay group", %{
      account: account,
      context: context,
      subject: subject
    } do
      group = Fixtures.Relays.create_group(account: account)

      assert {:ok, created_token, encoded_token} = create_token(group, %{}, subject)
      refute created_token.secret_nonce
      refute created_token.secret_fragment

      assert {:ok, fetched_group, fetched_token} = authenticate(encoded_token, context)
      assert fetched_group.id == group.id

      assert token = Repo.get_by(Tokens.Token, relay_group_id: fetched_group.id)
      assert token.id == fetched_token.id
      assert token.id == created_token.id
      assert token.type == :relay_group
      assert token.account_id == account.id
      assert token.relay_group_id == group.id
      assert token.created_by == :identity
      assert token.created_by_identity_id == subject.identity.id
      assert token.created_by_user_agent == context.user_agent
      assert token.created_by_remote_ip.address == context.remote_ip
      refute token.expires_at
    end

    test "returns error on missing permissions", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Relays.create_group(account: account)
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_token(group, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Relays.Authorizer.manage_relays_permission()]}}
    end
  end

  describe "authenticate/2" do
    setup do
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      %{
        context: %Domain.Auth.Context{
          type: :relay_group,
          remote_ip: remote_ip,
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.4501,
          remote_ip_location_lon: 30.5234,
          user_agent: user_agent
        }
      }
    end

    test "returns error when token is invalid", %{
      context: context
    } do
      assert authenticate(".foo", context) == {:error, :unauthorized}
      assert authenticate("foo", context) == {:error, :unauthorized}
    end

    test "returns error when context is invalid", %{
      context: context
    } do
      group = Fixtures.Relays.create_global_group()
      assert {:ok, _token, encoded_token} = create_token(group, %{})
      context = %{context | type: :client}

      assert authenticate(encoded_token, context) == {:error, :unauthorized}
    end

    test "returns global group when token is valid", %{
      context: context
    } do
      group = Fixtures.Relays.create_global_group()
      assert {:ok, _token, encoded_token} = create_token(group, %{})

      assert {:ok, fetched_group, _fetched_token} = authenticate(encoded_token, context)
      assert fetched_group.id == group.id
      refute fetched_group.account_id
    end

    test "returns group when token is valid", %{
      account: account,
      context: context,
      subject: subject
    } do
      group = Fixtures.Relays.create_group(account: account)
      assert {:ok, token, encoded_token} = create_token(group, %{}, subject)

      assert {:ok, fetched_group, fetched_token} = authenticate(encoded_token, context)
      assert fetched_group.id == group.id
      assert fetched_group.account_id == account.id
      assert fetched_token.id == token.id
    end
  end

  describe "fetch_relay_by_id/3" do
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
      assert fetch_relay_by_id(relay.id, subject, preload: :online?) == {:ok, relay}
    end

    test "returns relay that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      relay = Fixtures.Relays.create_relay(account: account)
      assert fetch_relay_by_id(relay.id, subject, preload: :online?) == {:ok, relay}
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
                 reason: :missing_permissions,
                 missing_permissions: [Relays.Authorizer.manage_relays_permission()]}}
    end
  end

  describe "list_relays/2" do
    test "returns empty list when there are no relays", %{subject: subject} do
      assert {:ok, [], _metadata} = list_relays(subject)
    end

    test "does not list deleted relays", %{
      subject: subject
    } do
      Fixtures.Relays.create_relay()
      |> Fixtures.Relays.delete_relay()

      assert {:ok, [], _metadata} = list_relays(subject)
    end

    test "returns all relays", %{
      account: account,
      subject: subject
    } do
      Fixtures.Relays.create_relay(account: account)
      Fixtures.Relays.create_relay(account: account)
      Fixtures.Relays.create_relay()

      group = Fixtures.Relays.create_global_group()
      relay = Fixtures.Relays.create_relay(account: account, group: group)

      assert {:ok, relays, _metadata} = list_relays(subject, preload: :online?)
      assert length(relays) == 3
      refute Enum.any?(relays, & &1.online?)

      :ok = connect_relay(relay, Ecto.UUID.generate())
      assert {:ok, relays, _metadata} = list_relays(subject, preload: :online?)
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
                 reason: :missing_permissions,
                 missing_permissions: [Relays.Authorizer.manage_relays_permission()]}}
    end
  end

  describe "all_connected_relays_for_account/1" do
    test "returns empty list when there are no relays online", %{account: account} do
      # managed
      global_group = Fixtures.Relays.create_global_group()
      Fixtures.Relays.create_relay(account: account, group: global_group)

      # self hosted
      Fixtures.Relays.create_relay(account: account)

      assert all_connected_relays_for_account(account) == {:ok, []}
    end

    # test "does not return relays connected less than 5 seconds ago", %{account: account} do
    #   relay = Fixtures.Relays.create_relay(account: account)
    #   assert connect_relay(relay, Ecto.UUID.generate()) == :ok

    #   Fixtures.Relays.update_relay(relay,
    #     last_seen_at: DateTime.utc_now() |> DateTime.add(-1, :second)
    #   )

    #   assert all_connected_relays_for_account(account) == {:ok, []}
    # end

    test "returns list of connected account relays", %{account: account} do
      relay1 = Fixtures.Relays.create_relay(account: account)
      relay2 = Fixtures.Relays.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()

      assert connect_relay(relay1, stamp_secret) == :ok
      assert connect_relay(relay2, stamp_secret) == :ok

      Fixtures.Relays.update_relay(relay1,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-6, :second)
      )

      Fixtures.Relays.update_relay(relay2,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-600, :second)
      )

      assert {:ok, connected_relays} = all_connected_relays_for_account(account)

      assert Enum.all?(connected_relays, &(&1.stamp_secret == stamp_secret))
      assert Enum.sort(Enum.map(connected_relays, & &1.id)) == Enum.sort([relay1.id, relay2.id])
    end

    test "returns list of connected global relays", %{account: account} do
      group = Fixtures.Relays.create_global_group()
      relay = Fixtures.Relays.create_relay(account: account, group: group)
      stamp_secret = Ecto.UUID.generate()

      assert connect_relay(relay, stamp_secret) == :ok

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      assert {:ok, [connected_relay]} = all_connected_relays_for_account(account)

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
    setup %{account: account} do
      group = Fixtures.Relays.create_group(account: account)
      token = Fixtures.Relays.create_token(account: account, group: group)

      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      %{
        group: group,
        token: token,
        context: %Domain.Auth.Context{
          type: :relay_group,
          remote_ip: remote_ip,
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.4501,
          remote_ip_location_lon: 30.5234,
          user_agent: user_agent
        }
      }
    end

    test "returns errors on invalid attrs", %{
      context: context,
      group: group,
      token: token
    } do
      attrs = %{
        ipv4: "1.1.1.256",
        ipv6: "fd01::10000",
        port: -1
      }

      assert {:error, changeset} = upsert_relay(group, token, attrs, context)

      assert errors_on(changeset) == %{
               ipv4: ["one of these fields must be present: ipv4, ipv6", "is invalid"],
               ipv6: ["one of these fields must be present: ipv4, ipv6", "is invalid"],
               port: ["must be greater than or equal to 1"]
             }

      attrs = %{port: 100_000}
      assert {:error, changeset} = upsert_relay(group, token, attrs, context)
      assert "must be less than or equal to 65535" in errors_on(changeset).port
    end

    test "allows creating relay with just required attributes", %{
      context: context,
      group: group,
      token: token
    } do
      attrs =
        Fixtures.Relays.relay_attrs()
        |> Map.delete(:name)

      assert {:ok, relay} = upsert_relay(group, token, attrs, context)

      assert relay.group_id == group.id

      assert relay.ipv4.address == attrs.ipv4
      assert relay.ipv6.address == attrs.ipv6

      assert relay.last_seen_remote_ip.address == context.remote_ip
      assert relay.last_seen_remote_ip_location_region == context.remote_ip_location_region
      assert relay.last_seen_remote_ip_location_city == context.remote_ip_location_city
      assert relay.last_seen_remote_ip_location_lat == context.remote_ip_location_lat
      assert relay.last_seen_remote_ip_location_lon == context.remote_ip_location_lon
      assert relay.last_seen_user_agent == context.user_agent
      assert relay.last_seen_version == "1.3.0"
      assert relay.last_seen_at
      assert relay.last_used_token_id == token.id
      assert relay.port == 3478

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end

    test "allows creating ipv6-only relays", %{
      context: context,
      group: group,
      token: token
    } do
      attrs =
        Fixtures.Relays.relay_attrs()
        |> Map.drop([:name, :ipv4])

      assert {:ok, _relay} = upsert_relay(group, token, attrs, context)
      assert {:ok, _relay} = upsert_relay(group, token, attrs, context)

      assert Repo.one(Relays.Relay)
    end

    test "updates ipv4 relay when it already exists", %{
      account: account,
      group: group,
      token: token,
      context: context
    } do
      relay = Fixtures.Relays.create_relay(account: account, group: group)
      attrs = Fixtures.Relays.relay_attrs(ipv4: relay.ipv4)
      context = %{context | user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"}

      assert {:ok, updated_relay} = upsert_relay(group, token, attrs, context)

      assert Repo.aggregate(Relays.Relay, :count, :id) == 1

      assert updated_relay.last_seen_remote_ip.address == context.remote_ip
      assert updated_relay.last_seen_user_agent == context.user_agent
      assert updated_relay.last_seen_user_agent != relay.last_seen_user_agent
      assert updated_relay.last_seen_version == "0.7.411"
      assert updated_relay.last_seen_at
      assert updated_relay.last_seen_at != relay.last_seen_at
      assert updated_relay.last_used_token_id == token.id

      assert updated_relay.group_id == group.id

      assert updated_relay.ipv4 == relay.ipv4
      assert updated_relay.ipv6.address == attrs.ipv6
      assert updated_relay.ipv6 != relay.ipv6
      assert updated_relay.port == 3478

      assert updated_relay.last_seen_remote_ip_location_region ==
               context.remote_ip_location_region

      assert updated_relay.last_seen_remote_ip_location_city == context.remote_ip_location_city
      assert updated_relay.last_seen_remote_ip_location_lat == context.remote_ip_location_lat
      assert updated_relay.last_seen_remote_ip_location_lon == context.remote_ip_location_lon

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end

    test "updates ipv6 relay when it already exists", %{
      context: context,
      account: account,
      group: group,
      token: token
    } do
      relay = Fixtures.Relays.create_relay(ipv4: nil, account: account, group: group)

      attrs =
        Fixtures.Relays.relay_attrs(
          ipv4: nil,
          ipv6: relay.ipv6
        )

      assert {:ok, updated_relay} = upsert_relay(group, token, attrs, context)

      assert Repo.aggregate(Relays.Relay, :count, :id) == 1

      assert updated_relay.last_seen_remote_ip.address == context.remote_ip
      assert updated_relay.last_seen_user_agent == context.user_agent
      assert updated_relay.last_seen_version == "1.3.0"
      assert updated_relay.last_seen_at
      assert updated_relay.last_seen_at != relay.last_seen_at
      assert updated_relay.last_used_token_id == token.id

      assert updated_relay.group_id == group.id

      assert updated_relay.ipv4 == nil
      assert updated_relay.ipv6.address == attrs.ipv6.address
      assert updated_relay.port == 3478

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end

    test "updates global relay when it already exists", %{context: context} do
      group = Fixtures.Relays.create_global_group()
      token = Fixtures.Relays.create_global_token(group: group)
      relay = Fixtures.Relays.create_relay(group: group)
      context = %{context | user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"}
      attrs = Fixtures.Relays.relay_attrs(ipv4: relay.ipv4)

      assert {:ok, updated_relay} = upsert_relay(group, token, attrs, context)

      assert Repo.aggregate(Relays.Relay, :count, :id) == 1

      assert updated_relay.last_seen_remote_ip.address == context.remote_ip
      assert updated_relay.last_seen_user_agent == context.user_agent
      assert updated_relay.last_seen_user_agent != relay.last_seen_user_agent
      assert updated_relay.last_seen_version == "0.7.411"
      assert updated_relay.last_seen_at
      assert updated_relay.last_seen_at != relay.last_seen_at
      assert updated_relay.last_used_token_id == token.id

      assert updated_relay.group_id == group.id

      assert updated_relay.ipv4 == relay.ipv4
      assert updated_relay.ipv6.address == attrs.ipv6
      assert updated_relay.ipv6 != relay.ipv6
      assert updated_relay.port == 3478

      assert Repo.aggregate(Domain.Network.Address, :count) == 0
    end

    test "creates multiple relays when only port changes", %{
      account: account,
      group: group
    } do
      ipv4 = Domain.Fixture.unique_ipv4()
      ipv6 = Domain.Fixture.unique_ipv6()
      first_port = Domain.Fixture.unique_integer()
      second_port = Domain.Fixture.unique_integer()

      first_relay =
        Fixtures.Relays.create_relay(
          ipv4: ipv4,
          ipv6: ipv6,
          port: first_port,
          account: account,
          group: group
        )

      second_relay =
        Fixtures.Relays.create_relay(
          ipv4: ipv4,
          ipv6: ipv6,
          port: second_port,
          account: account,
          group: group
        )

      assert first_relay.ipv4 == second_relay.ipv4
      assert first_relay.ipv6 == second_relay.ipv6
      assert first_relay.port == first_port
      assert second_relay.port == second_port

      assert Repo.aggregate(Relays.Relay, :count, :id) == 2
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
                 reason: :missing_permissions,
                 missing_permissions: [Relays.Authorizer.manage_relays_permission()]}}
    end
  end

  describe "load_balance_relays/2" do
    test "returns empty list when there are no relays" do
      assert load_balance_relays({0, 0}, []) == []
    end

    test "returns 2 random relays when there are no coordinates" do
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
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      relay_2 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: nil,
            remote_ip_location_lon: nil
          ]
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
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      relay_us_east_2 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      relays = [
        relay_us_east_1,
        relay_us_east_2
      ]

      assert [relay1] = load_balance_relays({32.2029, -80.0131}, relays)
      assert relay1.id in [relay_us_east_1.id, relay_us_east_2.id]
    end

    test "returns at most two relays - one from each location location" do
      relay_us_east_1 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      relay_us_east_2 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      relay_us_east_3 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      us_east_relays = [
        relay_us_east_1,
        relay_us_east_2,
        relay_us_east_3
      ]

      # The Dalles, Oregon
      relay_us_west_1 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 45.5946,
            remote_ip_location_lon: -121.1787
          ]
        )

      relay_us_west_2 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 45.5946,
            remote_ip_location_lon: -121.1787
          ]
        )

      relay_us_west_3 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 45.5946,
            remote_ip_location_lon: -121.1787
          ]
        )

      # Ukraine
      relay_eu_east_1 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 50.4501,
            remote_ip_location_lon: 30.5234
          ]
        )

      eu_east_relays = [
        relay_eu_east_1
      ]

      us_west_relays = [
        relay_us_west_1,
        relay_us_west_2,
        relay_us_west_3
      ]

      us_east_relay_ids = Enum.map(us_east_relays, & &1.id)
      us_west_relay_ids = Enum.map(us_west_relays, & &1.id)

      relays = us_east_relays ++ us_west_relays ++ eu_east_relays

      assert relays = load_balance_relays({32.2029, -80.0131}, relays)
      assert length(relays) == 2
      assert Enum.any?(relays, &(&1.id in us_east_relay_ids))
      assert Enum.any?(relays, &(&1.id in us_west_relay_ids))

      assert relays = load_balance_relays({45.5946, -121.1787}, relays)
      assert length(relays) == 2
      assert Enum.any?(relays, &(&1.id in us_east_relay_ids))
      assert Enum.any?(relays, &(&1.id in us_west_relay_ids))

      assert relays = load_balance_relays({32.2029, -80.0131}, us_west_relays)
      assert length(relays) == 1
      assert Enum.all?(relays, &(&1.id in us_west_relay_ids))
    end

    test "selects relays in two closest regions to a given location" do
      # Moncks Corner, South Carolina
      relay_us_east_1 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      relay_us_east_2 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      relay_us_east_3 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      # The Dalles, Oregon
      relay_us_west_1 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 45.5946,
            remote_ip_location_lon: -121.1787
          ]
        )

      relay_us_west_2 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 45.5946,
            remote_ip_location_lon: -121.1787
          ]
        )

      # Council Bluffs, Iowa
      relay_us_central_1 =
        Fixtures.Relays.create_relay(
          context: [
            remote_ip_location_lat: 41.2619,
            remote_ip_location_lon: -95.8608
          ]
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

  describe "connect_relay/2" do
    test "does not allow duplicate presence", %{account: account} do
      relay = Fixtures.Relays.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()

      assert connect_relay(relay, stamp_secret) == :ok
      assert {:error, {:already_tracked, _pid, _topic, _key}} = connect_relay(relay, stamp_secret)
    end

    test "tracks relay presence for account", %{account: account} do
      relay = Fixtures.Relays.create_relay(account: account)
      assert connect_relay(relay, "foo") == :ok

      relay = fetch_relay_by_id!(relay.id, preload: [:online?])
      assert relay.online? == true
    end

    test "tracks relay presence for actor", %{account: account} do
      relay = Fixtures.Relays.create_relay(account: account)
      assert connect_relay(relay, "foo") == :ok

      assert broadcast_to_relay(relay, "test") == :ok

      assert_receive "test"
    end

    test "subscribes to relay events", %{account: account} do
      relay = Fixtures.Relays.create_relay(account: account)
      assert connect_relay(relay, "foo") == :ok

      assert disconnect_relay(relay) == :ok

      assert_receive "disconnect"
    end

    test "subscribes to relay group events", %{account: account} do
      group = Fixtures.Relays.create_group(account: account)
      relay = Fixtures.Relays.create_relay(account: account, group: group)

      assert connect_relay(relay, "foo") == :ok

      assert disconnect_relays_in_group(group) == :ok

      assert_receive "disconnect"
    end

    test "subscribes to account events", %{account: account} do
      relay = Fixtures.Relays.create_relay(account: account)

      assert connect_relay(relay, "foo") == :ok

      assert disconnect_relays_in_account(account) == :ok

      assert_receive "disconnect"
    end

    test "subscribes to relay presence", %{account: account} do
      relay = Fixtures.Relays.create_relay(account: account)
      :ok = subscribe_to_relay_presence(relay)

      assert connect_relay(relay, "foo") == :ok

      relay_id = relay.id
      assert_receive %Phoenix.Socket.Broadcast{topic: "presences:relays:" <> ^relay_id}
    end
  end
end
