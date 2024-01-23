defmodule Domain.GatewaysTest do
  use Domain.DataCase, async: true
  import Domain.Gateways
  alias Domain.{Gateways, Tokens}

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
      group = Fixtures.Gateways.create_group()
      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "returns deleted groups", %{
      account: account,
      subject: subject
    } do
      group =
        Fixtures.Gateways.create_group(account: account)
        |> Fixtures.Gateways.delete_group()

      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group by id", %{account: account, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account)
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account)
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
                 missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]}}
    end
  end

  describe "fetch_group_by_id/1" do
    test "returns error when UUID is invalid" do
      assert fetch_group_by_id("foo") == {:error, :not_found}
    end

    test "does not return deleted groups", %{account: account} do
      group =
        Fixtures.Gateways.create_group(account: account)
        |> Fixtures.Gateways.delete_group()

      assert fetch_group_by_id(group.id) == {:error, :not_found}
    end

    test "returns group by id", %{account: account} do
      group = Fixtures.Gateways.create_group(account: account)
      assert {:ok, fetched_group} = fetch_group_by_id(group.id)
      assert fetched_group.id == group.id
    end

    test "returns error when group does not exist" do
      assert fetch_group_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "list_groups/1" do
    test "returns empty list when there are no groups", %{subject: subject} do
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list groups from other accounts", %{
      subject: subject
    } do
      Fixtures.Gateways.create_group()
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list deleted groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Gateways.create_group(account: account)
      |> Fixtures.Gateways.delete_group()

      assert list_groups(subject) == {:ok, []}
    end

    test "returns all groups", %{
      account: account,
      subject: subject
    } do
      Fixtures.Gateways.create_group(account: account)
      Fixtures.Gateways.create_group(account: account)
      Fixtures.Gateways.create_group()

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
                 missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]}}
    end
  end

  describe "new_group/0" do
    test "returns group changeset" do
      assert %Ecto.Changeset{data: %Gateways.Group{}, changes: changes} = new_group()
      assert Map.has_key?(changes, :name)
      assert Enum.count(changes) == 1
    end
  end

  describe "create_group/2" do
    test "returns error on empty attrs", %{subject: subject} do
      assert {:error, changeset} = create_group(%{}, subject)
      assert errors_on(changeset) == %{routing: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      attrs = %{
        name: String.duplicate("A", 65)
      }

      assert {:error, changeset} = create_group(attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"],
               routing: ["can't be blank"]
             }

      Fixtures.Gateways.create_group(account: account, name: "foo")
      attrs = %{name: "foo", routing: "managed"}
      assert {:error, changeset} = create_group(attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "returns error on invalid routing value", %{subject: subject} do
      attrs = %{
        name_prefix: "foo",
        routing: "foo"
      }

      assert {:error, changeset} = create_group(attrs, subject)

      assert errors_on(changeset) == %{
               routing: ["is invalid"]
             }
    end

    test "creates a group", %{subject: subject} do
      attrs = %{
        name: "foo",
        routing: "managed"
      }

      assert {:ok, group} = create_group(attrs, subject)
      assert group.id
      assert group.name == "foo"

      assert group.created_by == :identity
      assert group.created_by_identity_id == subject.identity.id

      assert group.routing == :managed
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_group(%{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]}}
    end
  end

  describe "change_group/1" do
    test "returns changeset with given changes" do
      group = Fixtures.Gateways.create_group()

      group_attrs =
        Fixtures.Gateways.group_attrs()
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
      group = Fixtures.Gateways.create_group()
      attrs = %{name: nil}

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account)

      attrs = %{
        name: String.duplicate("A", 65),
        routing: "foo"
      }

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"],
               routing: ["is invalid"]
             }

      Fixtures.Gateways.create_group(account: account, name: "foo")
      attrs = %{name: "foo"}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "updates a group", %{account: account, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account)

      attrs = %{
        name: "foo",
        routing: "stun_only"
      }

      assert {:ok, group} = update_group(group, attrs, subject)
      assert group.name == "foo"
      assert group.routing == :stun_only
    end

    test "broadcasts disconnect message to all connected gateways", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      :ok = Gateways.connect_gateway(gateway)

      assert {:ok, _group} = update_group(group, %{routing: "stun_only"}, subject)

      assert_receive "disconnect"
    end

    test "returns error when subject has no permission to manage groups", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account)

      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_group(group, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]}}
    end
  end

  describe "delete_group/2" do
    test "returns error on state conflict", %{account: account, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert delete_group(deleted, subject) == {:error, :not_found}
      assert delete_group(group, subject) == {:error, :not_found}
    end

    test "deletes groups", %{account: account, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at
    end

    test "deletes all tokens when group is deleted", %{account: account, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account)
      Fixtures.Gateways.create_token(account: account, group: group)
      Fixtures.Gateways.create_token(account: account, group: [account: account])

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at

      tokens =
        Domain.Tokens.Token.Query.all()
        |> Domain.Tokens.Token.Query.by_gateway_group_id(group.id)
        |> Repo.all()
        |> Enum.filter(fn token -> token.gateway_group_id == group.id end)

      assert length(tokens) > 0
      assert Enum.all?(tokens, & &1.deleted_at)
    end

    test "deletes all gateways when group is deleted", %{account: account, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account)
      Fixtures.Gateways.create_gateway(account: account, group: group)

      assert {:ok, _group} = delete_group(group, subject)

      gateways =
        Domain.Gateways.Gateway.Query.all()
        |> Domain.Gateways.Gateway.Query.by_group_id(group.id)
        |> Repo.all()

      assert length(gateways) > 0
      assert Enum.all?(gateways, & &1.deleted_at)
    end

    test "broadcasts disconnect message to all connected gateway sockets", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account)

      token1 = Fixtures.Gateways.create_token(account: account, group: group)
      Domain.PubSub.subscribe(Tokens.socket_id(token1))

      token2 = Fixtures.Gateways.create_token(account: account, group: group)
      Domain.PubSub.subscribe(Tokens.socket_id(token2))

      Fixtures.Gateways.create_gateway(account: account, group: group)

      assert {:ok, _group} = delete_group(group, subject)

      assert_receive "disconnect"
      assert_receive "disconnect"
    end

    test "broadcasts disconnect message to all connected gateways", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      :ok = Gateways.connect_gateway(gateway)

      assert {:ok, _group} = delete_group(group, subject)

      assert_receive "disconnect"
    end

    test "returns error when subject has no permission to delete groups", %{
      subject: subject
    } do
      group = Fixtures.Gateways.create_group()

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_group(group, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]}}
    end
  end

  describe "create_token/3" do
    setup do
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      %{
        context: %Domain.Auth.Context{
          type: :gateway_group,
          remote_ip: remote_ip,
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.4501,
          remote_ip_location_lon: 30.5234,
          user_agent: user_agent
        }
      }
    end

    test "returns valid token for a gateway group", %{
      account: account,
      context: context,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account)

      assert {:ok, encoded_token} = create_token(group, %{}, subject)

      assert {:ok, fetched_group, fetched_token} = authenticate(encoded_token, context)
      assert fetched_group.id == group.id

      assert token = Repo.get_by(Tokens.Token, gateway_group_id: fetched_group.id)
      assert token.id == fetched_token.id
      assert token.type == :gateway_group
      assert token.account_id == account.id
      assert token.gateway_group_id == group.id
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
      group = Fixtures.Gateways.create_group(account: account)
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_token(group, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]}}
    end
  end

  describe "authenticate/2" do
    setup do
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      %{
        context: %Domain.Auth.Context{
          type: :gateway_group,
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
      account: account,
      context: context,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account)
      assert {:ok, encoded_token} = create_token(group, %{}, subject)
      context = %{context | type: :client}

      assert authenticate(encoded_token, context) == {:error, :unauthorized}
    end

    test "returns group when token is valid", %{
      account: account,
      context: context,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account)
      assert {:ok, encoded_token} = create_token(group, %{}, subject)

      assert {:ok, fetched_group, _fetched_token} = authenticate(encoded_token, context)
      assert fetched_group.id == group.id
      assert fetched_group.account_id == account.id
    end
  end

  describe "fetch_gateway_by_id/2" do
    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_gateway_by_id("foo", subject) == {:error, :not_found}
    end

    test "does not return gateways from other accounts", %{
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway()
      assert fetch_gateway_by_id(gateway.id, subject) == {:error, :not_found}
    end

    test "returns deleted gateways", %{
      account: account,
      subject: subject
    } do
      gateway =
        Fixtures.Gateways.create_gateway(account: account)
        |> Fixtures.Gateways.delete_gateway()

      assert fetch_gateway_by_id(gateway.id, subject) == {:ok, gateway}
    end

    test "returns gateway by id", %{account: account, subject: subject} do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      assert fetch_gateway_by_id(gateway.id, subject) == {:ok, gateway}
    end

    test "returns gateway that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      assert fetch_gateway_by_id(gateway.id, subject) == {:ok, gateway}
    end

    test "returns error when gateway does not exist", %{subject: subject} do
      assert fetch_gateway_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view gateways", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_gateway_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Gateways.Authorizer.manage_gateways_permission(),
                      Gateways.Authorizer.connect_gateways_permission()
                    ]}
                 ]}}
    end

    # TODO: add a test that soft-deleted assocs are not preloaded
    test "associations are preloaded when opts given", %{account: account, subject: subject} do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      {:ok, gateway} = fetch_gateway_by_id(gateway.id, subject, preload: [:group, :account])

      assert Ecto.assoc_loaded?(gateway.group)
      assert Ecto.assoc_loaded?(gateway.account)
    end
  end

  describe "list_gateways/1" do
    test "returns empty list when there are no gateways", %{subject: subject} do
      assert list_gateways(subject) == {:ok, []}
    end

    test "does not list deleted gateways", %{
      subject: subject
    } do
      Fixtures.Gateways.create_gateway()
      |> Fixtures.Gateways.delete_gateway()

      assert list_gateways(subject) == {:ok, []}
    end

    test "returns all gateways", %{
      account: account,
      subject: subject
    } do
      offline_gateway = Fixtures.Gateways.create_gateway(account: account)
      online_gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = connect_gateway(online_gateway)
      Fixtures.Gateways.create_gateway()

      assert {:ok, gateways} = list_gateways(subject)
      assert length(gateways) == 2

      online_gateway_id = online_gateway.id
      offline_gateway_id = offline_gateway.id

      assert %{
               true: [%{id: ^online_gateway_id}],
               false: [%{id: ^offline_gateway_id}]
             } = Enum.group_by(gateways, & &1.online?)
    end

    test "returns error when subject has no permission to manage gateways", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_gateways(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]}}
    end

    # TODO: add a test that soft-deleted assocs are not preloaded
    test "associations are preloaded when opts given", %{account: account, subject: subject} do
      Fixtures.Gateways.create_gateway(account: account)
      Fixtures.Gateways.create_gateway(account: account)

      {:ok, gateways} = list_gateways(subject, preload: [:group, :account])
      assert length(gateways) == 2

      assert Enum.all?(gateways, &Ecto.assoc_loaded?(&1.group))
      assert Enum.all?(gateways, &Ecto.assoc_loaded?(&1.account))
    end
  end

  describe "list_connected_gateways_for_resource/1" do
    test "returns empty list when there are no online gateways", %{account: account} do
      resource = Fixtures.Resources.create_resource(account: account)

      Fixtures.Gateways.create_gateway(account: account)

      Fixtures.Gateways.create_gateway(account: account)
      |> Fixtures.Gateways.delete_gateway()

      assert list_connected_gateways_for_resource(resource) == {:ok, []}
    end

    test "returns list of connected gateways for a given resource", %{account: account} do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway.group_id}]
        )

      assert connect_gateway(gateway) == :ok

      assert {:ok, [connected_gateway]} = list_connected_gateways_for_resource(resource)
      assert connected_gateway.id == gateway.id
    end

    test "does not return connected gateways that are not connected to given resource", %{
      account: account
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      gateway = Fixtures.Gateways.create_gateway(account: account)

      assert connect_gateway(gateway) == :ok

      assert list_connected_gateways_for_resource(resource) == {:ok, []}
    end
  end

  describe "gateway_can_connect_to_resource?/2" do
    test "returns true when gateway can connect to resource", %{account: account} do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = connect_gateway(gateway)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway.group_id}]
        )

      assert gateway_can_connect_to_resource?(gateway, resource)
    end

    test "returns false when gateway cannot connect to resource", %{account: account} do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = connect_gateway(gateway)

      resource = Fixtures.Resources.create_resource(account: account)

      refute gateway_can_connect_to_resource?(gateway, resource)
    end

    test "returns false when gateway is offline", %{account: account} do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      resource = Fixtures.Resources.create_resource(account: account)

      refute gateway_can_connect_to_resource?(gateway, resource)
    end
  end

  describe "change_gateway/1" do
    test "returns changeset with given changes" do
      gateway = Fixtures.Gateways.create_gateway()
      gateway_attrs = Fixtures.Gateways.gateway_attrs()

      assert changeset = change_gateway(gateway, gateway_attrs)
      assert %Ecto.Changeset{data: %Domain.Gateways.Gateway{}} = changeset

      assert changeset.changes == %{name: gateway_attrs.name}
    end
  end

  describe "upsert_gateway/3" do
    setup %{account: account} do
      group = Fixtures.Gateways.create_group(account: account)

      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      %{
        group: group,
        context: %Domain.Auth.Context{
          type: :gateway_group,
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
      group: group
    } do
      attrs = %{
        external_id: nil,
        public_key: "x"
      }

      assert {:error, changeset} = upsert_gateway(group, attrs, context)

      assert errors_on(changeset) == %{
               public_key: ["should be 44 character(s)", "must be a base64-encoded string"],
               external_id: ["can't be blank"]
             }
    end

    test "allows creating gateway with just required attributes", %{
      context: context,
      group: group
    } do
      attrs =
        Fixtures.Gateways.gateway_attrs()
        |> Map.delete(:name)

      assert {:ok, gateway} = upsert_gateway(group, attrs, context)

      assert gateway.name
      assert gateway.public_key == attrs.public_key

      assert gateway.group_id == group.id

      refute is_nil(gateway.ipv4)
      refute is_nil(gateway.ipv6)

      assert gateway.last_seen_remote_ip.address == context.remote_ip
      assert gateway.last_seen_user_agent == context.user_agent
      assert gateway.last_seen_version == "0.7.412"
      assert gateway.last_seen_at
      assert gateway.last_seen_remote_ip_location_region == context.remote_ip_location_region
      assert gateway.last_seen_remote_ip_location_city == context.remote_ip_location_city
      assert gateway.last_seen_remote_ip_location_lat == context.remote_ip_location_lat
      assert gateway.last_seen_remote_ip_location_lon == context.remote_ip_location_lon
    end

    test "updates gateway when it already exists", %{
      account: account,
      context: context,
      group: group
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)
      attrs = Fixtures.Gateways.gateway_attrs(external_id: gateway.external_id)

      context = %{
        context
        | remote_ip: {100, 64, 100, 158},
          user_agent: "iOS/12.5 (iPhone) connlib/0.7.413"
      }

      assert {:ok, updated_gateway} = upsert_gateway(group, attrs, context)

      assert Repo.aggregate(Gateways.Gateway, :count, :id) == 1

      assert updated_gateway.name != gateway.name
      assert updated_gateway.last_seen_remote_ip.address == context.remote_ip
      assert updated_gateway.last_seen_remote_ip != gateway.last_seen_remote_ip
      assert updated_gateway.last_seen_user_agent == context.user_agent
      assert updated_gateway.last_seen_user_agent != gateway.last_seen_user_agent
      assert updated_gateway.last_seen_version == "0.7.413"
      assert updated_gateway.last_seen_at
      assert updated_gateway.last_seen_at != gateway.last_seen_at
      assert updated_gateway.public_key != gateway.public_key
      assert updated_gateway.public_key == attrs.public_key

      assert updated_gateway.group_id == group.id

      assert updated_gateway.ipv4 == gateway.ipv4
      assert updated_gateway.ipv6 == gateway.ipv6

      assert updated_gateway.last_seen_remote_ip_location_region ==
               context.remote_ip_location_region

      assert updated_gateway.last_seen_remote_ip_location_city ==
               context.remote_ip_location_city

      assert updated_gateway.last_seen_remote_ip_location_lat ==
               context.remote_ip_location_lat

      assert updated_gateway.last_seen_remote_ip_location_lon ==
               context.remote_ip_location_lon
    end

    test "does not reserve additional addresses on update", %{
      account: account,
      context: context,
      group: group
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      attrs =
        Fixtures.Gateways.gateway_attrs(
          external_id: gateway.external_id,
          last_seen_user_agent: "iOS/12.5 (iPhone) connlib/0.7.411",
          last_seen_remote_ip: %Postgrex.INET{address: {100, 64, 100, 100}}
        )

      assert {:ok, updated_gateway} = upsert_gateway(group, attrs, context)

      addresses =
        Domain.Network.Address
        |> Repo.all()
        |> Enum.map(fn %Domain.Network.Address{address: address, type: type} ->
          %{address: address, type: type}
        end)

      assert length(addresses) == 2
      assert %{address: updated_gateway.ipv4, type: :ipv4} in addresses
      assert %{address: updated_gateway.ipv6, type: :ipv6} in addresses
    end

    test "does not allow to reuse IP addresses", %{
      account: account,
      context: context,
      group: group
    } do
      attrs = Fixtures.Gateways.gateway_attrs()
      assert {:ok, gateway} = upsert_gateway(group, attrs, context)

      addresses =
        Domain.Network.Address
        |> Repo.all()
        |> Enum.map(fn %Domain.Network.Address{address: address, type: type} ->
          %{address: address, type: type}
        end)

      assert length(addresses) == 2
      assert %{address: gateway.ipv4, type: :ipv4} in addresses
      assert %{address: gateway.ipv6, type: :ipv6} in addresses

      assert_raise Ecto.ConstraintError, fn ->
        Fixtures.Network.create_address(account: account, address: gateway.ipv4)
      end
    end
  end

  describe "update_gateway/3" do
    test "updates gateways", %{account: account, subject: subject} do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      attrs = %{name: "Foo"}

      assert {:ok, gateway} = update_gateway(gateway, attrs, subject)

      assert gateway.name == attrs.name
    end

    test "does not allow to reset required fields to empty values", %{
      account: account,
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      attrs = %{name: nil}

      assert {:error, changeset} = update_gateway(gateway, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      attrs = %{
        name: String.duplicate("a", 256)
      }

      assert {:error, changeset} = update_gateway(gateway, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"]
             }
    end

    test "ignores updates for any field except name", %{
      account: account,
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      fields = Gateways.Gateway.__schema__(:fields) -- [:name]
      value = -1

      for field <- fields do
        assert {:ok, updated_gateway} = update_gateway(gateway, %{field => value}, subject)
        assert updated_gateway == gateway
      end
    end

    test "returns error when subject has no permission to update gateways", %{
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway()

      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_gateway(gateway, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]}}
    end
  end

  describe "delete_gateway/2" do
    test "returns error on state conflict", %{account: account, subject: subject} do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      assert {:ok, deleted} = delete_gateway(gateway, subject)
      assert delete_gateway(deleted, subject) == {:error, :not_found}
      assert delete_gateway(gateway, subject) == {:error, :not_found}
    end

    test "deletes gateways", %{account: account, subject: subject} do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      assert {:ok, deleted} = delete_gateway(gateway, subject)
      assert deleted.deleted_at
    end

    test "returns error when subject has no permission to delete gateways", %{
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway()

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_gateway(gateway, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]}}
    end
  end

  describe "load_balance_gateways/2" do
    test "returns nil when there are no gateways" do
      assert load_balance_gateways({0, 0}, []) == nil
    end

    test "returns random gateway" do
      gateways = Enum.map(1..10, fn _ -> Fixtures.Gateways.create_gateway() end)
      assert Enum.member?(gateways, load_balance_gateways({0, 0}, gateways))
    end

    test "returns random gateways when there are no coordinates" do
      gateway_1 = Fixtures.Gateways.create_gateway()
      gateway_2 = Fixtures.Gateways.create_gateway()
      gateway_3 = Fixtures.Gateways.create_gateway()

      assert gateway = load_balance_gateways({nil, nil}, [gateway_1, gateway_2, gateway_3])
      assert gateway.id in [gateway_1.id, gateway_2.id, gateway_3.id]
    end

    test "prioritizes gateways with known location" do
      gateway_1 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      gateway_2 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: nil,
            remote_ip_location_lon: nil
          ]
        )

      gateways = [
        gateway_1,
        gateway_2
      ]

      assert gateway = load_balance_gateways({32.2029, -80.0131}, gateways)
      assert gateway.id == gateway_1.id
    end

    test "prioritizes gateways of more recent version" do
      gateway_1 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131,
            user_agent: "iOS/12.7 (iPhone) connlib/1.99"
          ]
        )

      gateway_2 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131,
            user_agent: "iOS/12.7 (iPhone) connlib/2.3"
          ]
        )

      gateways = [
        gateway_1,
        gateway_2
      ]

      assert gateway = load_balance_gateways({32.2029, -80.0131}, gateways)
      assert gateway.id == gateway_2.id
    end

    test "returns gateways in two closest regions to a given location" do
      # Moncks Corner, South Carolina
      gateway_us_east_1 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      gateway_us_east_2 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      gateway_us_east_3 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: 33.2029,
            remote_ip_location_lon: -80.0131
          ]
        )

      # The Dalles, Oregon
      gateway_us_west_1 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: 45.5946,
            remote_ip_location_lon: -121.1787
          ]
        )

      gateway_us_west_2 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: 45.5946,
            remote_ip_location_lon: -121.1787
          ]
        )

      # Council Bluffs, Iowa
      gateway_us_central_1 =
        Fixtures.Gateways.create_gateway(
          context: [
            remote_ip_location_lat: 41.2619,
            remote_ip_location_lon: -95.8608
          ]
        )

      gateways = [
        gateway_us_east_1,
        gateway_us_east_2,
        gateway_us_east_3,
        gateway_us_west_1,
        gateway_us_west_2,
        gateway_us_central_1
      ]

      # multiple attempts are used to increase chances that all gateways in a group are randomly selected
      selected =
        for _ <- 0..12 do
          assert gateway = load_balance_gateways({32.2029, -80.0131}, gateways)
          assert gateway.id in [gateway_us_east_1.id, gateway_us_east_2.id, gateway_us_east_3.id]
          gateway.id
        end

      assert selected |> Enum.uniq() |> length() >= 2

      for _ <- 0..2 do
        assert gateway = load_balance_gateways({45.5946, -121.1787}, gateways)
        assert gateway.id in [gateway_us_west_1.id, gateway_us_west_2.id]
      end

      assert gateway = load_balance_gateways({42.2619, -96.8608}, gateways)
      assert gateway.id == gateway_us_central_1.id
    end
  end

  describe "load_balance_gateways/3" do
    test "returns random gateway if no gateways are already connected" do
      gateways = Enum.map(1..10, fn _ -> Fixtures.Gateways.create_gateway() end)
      assert Enum.member?(gateways, load_balance_gateways({0, 0}, gateways, []))
    end

    test "reuses gateway that is already connected to reduce the latency" do
      gateways = Enum.map(1..10, fn _ -> Fixtures.Gateways.create_gateway() end)
      [connected_gateway | _] = gateways

      assert load_balance_gateways({0, 0}, gateways, [connected_gateway.id]) == connected_gateway
    end

    test "returns random gateway from the connected ones" do
      gateways = Enum.map(1..10, fn _ -> Fixtures.Gateways.create_gateway() end)
      [connected_gateway1, connected_gateway2 | _] = gateways

      assert load_balance_gateways({0, 0}, gateways, [
               connected_gateway1.id,
               connected_gateway2.id
             ]) in [
               connected_gateway1,
               connected_gateway2
             ]
    end
  end

  describe "relay_strategy/1" do
    test "managed strategy" do
      group = Fixtures.Gateways.create_group(routing: :managed)
      assert {:managed, :turn} == relay_strategy([group])
    end

    test "self-hosted strategy" do
      group = Fixtures.Gateways.create_group(routing: :self_hosted)
      assert {:self_hosted, :turn} == relay_strategy([group])
    end

    test "stun_only strategy" do
      group = Fixtures.Gateways.create_group(routing: :stun_only)
      assert {:managed, :stun} == relay_strategy([group])
    end

    test "strictest strategy is returned" do
      managed_group = Fixtures.Gateways.create_group(routing: :managed)
      self_hosted_group = Fixtures.Gateways.create_group(routing: :self_hosted)
      stun_only_group = Fixtures.Gateways.create_group(routing: :stun_only)

      assert {:managed, :stun} ==
               relay_strategy([managed_group, self_hosted_group, stun_only_group])

      assert {:self_hosted, :turn} == relay_strategy([managed_group, self_hosted_group])
      assert {:managed, :stun} == relay_strategy([managed_group, stun_only_group])
      assert {:managed, :stun} == relay_strategy([self_hosted_group, stun_only_group])
      assert {:managed, :turn} == relay_strategy([managed_group])
    end
  end

  describe "connect_gateway/2" do
    test "does not allow duplicate presence", %{account: account} do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      assert connect_gateway(gateway) == :ok
      assert {:error, {:already_tracked, _pid, _topic, _key}} = connect_gateway(gateway)
    end
  end
end
