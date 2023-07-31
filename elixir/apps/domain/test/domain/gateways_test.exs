defmodule Domain.GatewaysTest do
  use Domain.DataCase, async: true
  import Domain.Gateways
  alias Domain.{AccountsFixtures, ResourcesFixtures}
  alias Domain.{NetworkFixtures, ActorsFixtures, AuthFixtures, GatewaysFixtures}
  alias Domain.Gateways

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
      group = GatewaysFixtures.create_group()
      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "does not return deleted groups", %{
      account: account,
      subject: subject
    } do
      group =
        GatewaysFixtures.create_group(account: account)
        |> GatewaysFixtures.delete_group()

      assert fetch_group_by_id(group.id, subject) == {:error, :not_found}
    end

    test "returns group by id", %{account: account, subject: subject} do
      group = GatewaysFixtures.create_group(account: account)
      assert {:ok, fetched_group} = fetch_group_by_id(group.id, subject)
      assert fetched_group.id == group.id
    end

    test "returns group that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      group = GatewaysFixtures.create_group(account: account)
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
                 [missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]]}}
    end
  end

  describe "list_groups/1" do
    test "returns empty list when there are no groups", %{subject: subject} do
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list groups from other accounts", %{
      subject: subject
    } do
      GatewaysFixtures.create_group()
      assert list_groups(subject) == {:ok, []}
    end

    test "does not list deleted groups", %{
      account: account,
      subject: subject
    } do
      GatewaysFixtures.create_group(account: account)
      |> GatewaysFixtures.delete_group()

      assert list_groups(subject) == {:ok, []}
    end

    test "returns all groups", %{
      account: account,
      subject: subject
    } do
      GatewaysFixtures.create_group(account: account)
      GatewaysFixtures.create_group(account: account)
      GatewaysFixtures.create_group()

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
                 [missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]]}}
    end
  end

  describe "new_group/0" do
    test "returns group changeset" do
      assert %Ecto.Changeset{data: %Gateways.Group{}, changes: changes} = new_group()
      assert Map.has_key?(changes, :name_prefix)
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
        name_prefix: String.duplicate("A", 65),
        tags: Enum.map(1..129, &Integer.to_string/1)
      }

      assert {:error, changeset} = create_group(attrs, subject)

      assert errors_on(changeset) == %{
               tokens: ["can't be blank"],
               name_prefix: ["should be at most 64 character(s)"],
               tags: ["should have at most 128 item(s)"]
             }

      attrs = %{tags: ["A", "B", "A"]}
      assert {:error, changeset} = create_group(attrs, subject)
      assert "should not contain duplicates" in errors_on(changeset).tags

      attrs = %{tags: [String.duplicate("A", 65)]}
      assert {:error, changeset} = create_group(attrs, subject)
      assert "should be at most 64 characters long" in errors_on(changeset).tags

      GatewaysFixtures.create_group(account: account, name_prefix: "foo")
      attrs = %{name_prefix: "foo", tokens: [%{}]}
      assert {:error, changeset} = create_group(attrs, subject)
      assert "has already been taken" in errors_on(changeset).name_prefix
    end

    test "creates a group", %{subject: subject} do
      attrs = %{
        name_prefix: "foo",
        tags: ["bar"],
        tokens: [%{}]
      }

      assert {:ok, group} = create_group(attrs, subject)
      assert group.id
      assert group.name_prefix == "foo"
      assert group.tags == ["bar"]

      assert group.created_by == :identity
      assert group.created_by_identity_id == subject.identity.id

      assert [%Gateways.Token{} = token] = group.tokens
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
                 [missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]]}}
    end
  end

  describe "change_group/1" do
    test "returns changeset with given changes" do
      group = GatewaysFixtures.create_group()

      group_attrs =
        GatewaysFixtures.group_attrs()
        |> Map.delete(:tokens)

      assert changeset = change_group(group, group_attrs)
      assert changeset.valid?
      assert changeset.changes == %{name_prefix: group_attrs.name_prefix, tags: group_attrs.tags}
    end
  end

  describe "update_group/3" do
    test "does not allow to reset required fields to empty values", %{
      subject: subject
    } do
      group = GatewaysFixtures.create_group()
      attrs = %{name_prefix: nil}

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{name_prefix: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      group = GatewaysFixtures.create_group(account: account)

      attrs = %{
        name_prefix: String.duplicate("A", 65),
        tags: Enum.map(1..129, &Integer.to_string/1)
      }

      assert {:error, changeset} = update_group(group, attrs, subject)

      assert errors_on(changeset) == %{
               name_prefix: ["should be at most 64 character(s)"],
               tags: ["should have at most 128 item(s)"]
             }

      attrs = %{tags: ["A", "B", "A"]}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert "should not contain duplicates" in errors_on(changeset).tags

      attrs = %{tags: [String.duplicate("A", 65)]}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert "should be at most 64 characters long" in errors_on(changeset).tags

      GatewaysFixtures.create_group(account: account, name_prefix: "foo")
      attrs = %{name_prefix: "foo"}
      assert {:error, changeset} = update_group(group, attrs, subject)
      assert "has already been taken" in errors_on(changeset).name_prefix
    end

    test "updates a group", %{account: account, subject: subject} do
      group = GatewaysFixtures.create_group(account: account)

      attrs = %{
        name_prefix: "foo",
        tags: ["bar"]
      }

      assert {:ok, group} = update_group(group, attrs, subject)
      assert group.name_prefix == "foo"
      assert group.tags == ["bar"]
    end

    test "returns error when subject has no permission to manage groups", %{
      account: account,
      subject: subject
    } do
      group = GatewaysFixtures.create_group(account: account)

      subject = AuthFixtures.remove_permissions(subject)

      assert update_group(group, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]]}}
    end
  end

  describe "delete_group/2" do
    test "returns error on state conflict", %{account: account, subject: subject} do
      group = GatewaysFixtures.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert delete_group(deleted, subject) == {:error, :not_found}
      assert delete_group(group, subject) == {:error, :not_found}
    end

    test "deletes groups", %{account: account, subject: subject} do
      group = GatewaysFixtures.create_group(account: account)

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at
    end

    test "deletes all tokens when group is deleted", %{account: account, subject: subject} do
      group = GatewaysFixtures.create_group(account: account)
      GatewaysFixtures.create_token(group: group)
      GatewaysFixtures.create_token(group: [account: account])

      assert {:ok, deleted} = delete_group(group, subject)
      assert deleted.deleted_at

      tokens =
        Gateways.Token
        |> Repo.all()
        |> Enum.filter(fn token -> token.group_id == group.id end)

      assert Enum.all?(tokens, & &1.deleted_at)
    end

    test "returns error when subject has no permission to delete groups", %{
      subject: subject
    } do
      group = GatewaysFixtures.create_group()

      subject = AuthFixtures.remove_permissions(subject)

      assert delete_group(group, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]]}}
    end
  end

  describe "use_token_by_id_and_secret/2" do
    test "returns token when secret is valid" do
      token = GatewaysFixtures.create_token()
      assert {:ok, token} = use_token_by_id_and_secret(token.id, token.value)
      assert is_nil(token.value)
      # TODO: While we don't have token rotation implemented, the tokens are all multi-use
      # assert is_nil(token.hash)
      # refute is_nil(token.deleted_at)
    end

    # TODO: While we don't have token rotation implemented, the tokens are all multi-use
    # test "returns error when secret was already used" do
    #   token = GatewaysFixtures.create_token()

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
      token = GatewaysFixtures.create_token()
      assert use_token_by_id_and_secret(token.id, "bar") == {:error, :not_found}
    end
  end

  describe "fetch_gateway_by_id/2" do
    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_gateway_by_id("foo", subject) == {:error, :not_found}
    end

    test "does not return gateways from other accounts", %{
      subject: subject
    } do
      gateway = GatewaysFixtures.create_gateway()
      assert fetch_gateway_by_id(gateway.id, subject) == {:error, :not_found}
    end

    test "does not return deleted gateways", %{
      account: account,
      subject: subject
    } do
      gateway =
        GatewaysFixtures.create_gateway(account: account)
        |> GatewaysFixtures.delete_gateway()

      assert fetch_gateway_by_id(gateway.id, subject) == {:error, :not_found}
    end

    test "returns gateway by id", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)
      assert fetch_gateway_by_id(gateway.id, subject) == {:ok, gateway}
    end

    test "returns gateway that belongs to another actor", %{
      account: account,
      subject: subject
    } do
      gateway = GatewaysFixtures.create_gateway(account: account)
      assert fetch_gateway_by_id(gateway.id, subject) == {:ok, gateway}
    end

    test "returns error when gateway does not exist", %{subject: subject} do
      assert fetch_gateway_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view gateways", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert fetch_gateway_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]]}}
    end

    # TODO: add a test that soft-deleted assocs are not preloaded
    test "associations are preloaded when opts given", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)
      {:ok, gateway} = fetch_gateway_by_id(gateway.id, subject, preload: [:group, :account])

      assert Ecto.assoc_loaded?(gateway.group) == true
      assert Ecto.assoc_loaded?(gateway.account) == true
    end
  end

  describe "list_gateways/1" do
    test "returns empty list when there are no gateways", %{subject: subject} do
      assert list_gateways(subject) == {:ok, []}
    end

    test "does not list deleted gateways", %{
      subject: subject
    } do
      GatewaysFixtures.create_gateway()
      |> GatewaysFixtures.delete_gateway()

      assert list_gateways(subject) == {:ok, []}
    end

    test "returns all gateways", %{
      account: account,
      subject: subject
    } do
      GatewaysFixtures.create_gateway(account: account)
      GatewaysFixtures.create_gateway(account: account)
      GatewaysFixtures.create_gateway()

      assert {:ok, gateways} = list_gateways(subject)
      assert length(gateways) == 2
    end

    test "returns error when subject has no permission to manage gateways", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert list_gateways(subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]]}}
    end

    # TODO: add a test that soft-deleted assocs are not preloaded
    test "associations are preloaded when opts given", %{account: account, subject: subject} do
      GatewaysFixtures.create_gateway(account: account)
      GatewaysFixtures.create_gateway(account: account)

      {:ok, gateways} = list_gateways(subject, preload: [:group, :account])
      assert length(gateways) == 2

      assert Enum.all?(gateways, fn g -> Ecto.assoc_loaded?(g.group) end) == true
      assert Enum.all?(gateways, fn g -> Ecto.assoc_loaded?(g.account) end) == true
    end
  end

  describe "list_connected_gateways_for_resource/1" do
    test "returns empty list when there are no online gateways", %{account: account} do
      resource = ResourcesFixtures.create_resource(account: account)

      GatewaysFixtures.create_gateway(account: account)

      GatewaysFixtures.create_gateway(account: account)
      |> GatewaysFixtures.delete_gateway()

      assert list_connected_gateways_for_resource(resource) == {:ok, []}
    end

    test "returns list of connected gateways for a given resource", %{account: account} do
      gateway = GatewaysFixtures.create_gateway(account: account)

      resource =
        ResourcesFixtures.create_resource(
          account: account,
          gateway_groups: [%{gateway_group_id: gateway.group_id}]
        )

      assert connect_gateway(gateway) == :ok

      assert {:ok, [connected_gateway]} = list_connected_gateways_for_resource(resource)
      assert connected_gateway.id == gateway.id
    end

    test "does not return connected gateways that are not connected to given resource", %{
      account: account
    } do
      resource = ResourcesFixtures.create_resource(account: account)
      gateway = GatewaysFixtures.create_gateway(account: account)

      assert connect_gateway(gateway) == :ok

      assert list_connected_gateways_for_resource(resource) == {:ok, []}
    end
  end

  describe "change_gateway/1" do
    test "returns changeset with given changes" do
      gateway = GatewaysFixtures.create_gateway()
      gateway_attrs = GatewaysFixtures.gateway_attrs()

      assert changeset = change_gateway(gateway, gateway_attrs)
      assert %Ecto.Changeset{data: %Domain.Gateways.Gateway{}} = changeset

      assert changeset.changes == %{name_suffix: gateway_attrs.name_suffix}
    end
  end

  describe "upsert_gateway/3" do
    setup context do
      token = GatewaysFixtures.create_token(account: context.account)

      context
      |> Map.put(:token, token)
      |> Map.put(:group, token.group)
    end

    test "returns errors on invalid attrs", %{
      token: token
    } do
      attrs = %{
        external_id: nil,
        public_key: "x",
        last_seen_user_agent: "foo",
        last_seen_remote_ip: {256, 0, 0, 0}
      }

      assert {:error, changeset} = upsert_gateway(token, attrs)

      assert errors_on(changeset) == %{
               public_key: ["should be 44 character(s)", "must be a base64-encoded string"],
               external_id: ["can't be blank"],
               last_seen_user_agent: ["is invalid"]
             }
    end

    test "allows creating gateway with just required attributes", %{
      token: token
    } do
      attrs =
        GatewaysFixtures.gateway_attrs()
        |> Map.delete(:name)

      assert {:ok, gateway} = upsert_gateway(token, attrs)

      assert gateway.name_suffix
      assert gateway.public_key == attrs.public_key

      assert gateway.token_id == token.id
      assert gateway.group_id == token.group_id

      refute is_nil(gateway.ipv4)
      refute is_nil(gateway.ipv6)

      assert gateway.last_seen_remote_ip == attrs.last_seen_remote_ip
      assert gateway.last_seen_user_agent == attrs.last_seen_user_agent
      assert gateway.last_seen_version == "0.7.412"
      assert gateway.last_seen_at
    end

    test "updates gateway when it already exists", %{
      token: token
    } do
      gateway = GatewaysFixtures.create_gateway(token: token)

      attrs =
        GatewaysFixtures.gateway_attrs(
          external_id: gateway.external_id,
          last_seen_remote_ip: {100, 64, 100, 101},
          last_seen_user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"
        )

      assert {:ok, updated_gateway} = upsert_gateway(token, attrs)

      assert Repo.aggregate(Gateways.Gateway, :count, :id) == 1

      assert updated_gateway.name_suffix
      assert updated_gateway.last_seen_remote_ip.address == attrs.last_seen_remote_ip
      assert updated_gateway.last_seen_remote_ip != gateway.last_seen_remote_ip
      assert updated_gateway.last_seen_user_agent == attrs.last_seen_user_agent
      assert updated_gateway.last_seen_user_agent != gateway.last_seen_user_agent
      assert updated_gateway.last_seen_version == "0.7.411"
      assert updated_gateway.last_seen_at
      assert updated_gateway.last_seen_at != gateway.last_seen_at
      assert updated_gateway.public_key != gateway.public_key
      assert updated_gateway.public_key == attrs.public_key

      assert updated_gateway.token_id == token.id
      assert updated_gateway.group_id == token.group_id

      assert updated_gateway.ipv4 == gateway.ipv4
      assert updated_gateway.ipv6 == gateway.ipv6
    end

    test "does not reserve additional addresses on update", %{
      token: token
    } do
      gateway = GatewaysFixtures.create_gateway(token: token)

      attrs =
        GatewaysFixtures.gateway_attrs(
          external_id: gateway.external_id,
          last_seen_user_agent: "iOS/12.5 (iPhone) connlib/0.7.411",
          last_seen_remote_ip: %Postgrex.INET{address: {100, 64, 100, 100}}
        )

      assert {:ok, updated_gateway} = upsert_gateway(token, attrs)

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
      token: token
    } do
      attrs = GatewaysFixtures.gateway_attrs()
      assert {:ok, gateway} = upsert_gateway(token, attrs)

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
        NetworkFixtures.create_address(account: account, address: gateway.ipv4)
      end
    end
  end

  describe "update_gateway/3" do
    test "updates gateways", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)
      attrs = %{name_suffix: "Foo"}

      assert {:ok, gateway} = update_gateway(gateway, attrs, subject)

      assert gateway.name_suffix == attrs.name_suffix
    end

    test "does not allow to reset required fields to empty values", %{
      account: account,
      subject: subject
    } do
      gateway = GatewaysFixtures.create_gateway(account: account)
      attrs = %{name_suffix: nil}

      assert {:error, changeset} = update_gateway(gateway, attrs, subject)

      assert errors_on(changeset) == %{name_suffix: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)

      attrs = %{
        name_suffix: String.duplicate("a", 256)
      }

      assert {:error, changeset} = update_gateway(gateway, attrs, subject)

      assert errors_on(changeset) == %{
               name_suffix: ["should be at most 8 character(s)"]
             }
    end

    test "ignores updates for any field except name", %{
      account: account,
      subject: subject
    } do
      gateway = GatewaysFixtures.create_gateway(account: account)

      fields = Gateways.Gateway.__schema__(:fields) -- [:name_suffix]
      value = -1

      for field <- fields do
        assert {:ok, updated_gateway} = update_gateway(gateway, %{field => value}, subject)
        assert updated_gateway == gateway
      end
    end

    test "returns error when subject has no permission to update gateways", %{
      subject: subject
    } do
      gateway = GatewaysFixtures.create_gateway()

      subject = AuthFixtures.remove_permissions(subject)

      assert update_gateway(gateway, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]]}}
    end
  end

  describe "delete_gateway/2" do
    test "returns error on state conflict", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)

      assert {:ok, deleted} = delete_gateway(gateway, subject)
      assert delete_gateway(deleted, subject) == {:error, :not_found}
      assert delete_gateway(gateway, subject) == {:error, :not_found}
    end

    test "deletes gateways", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)

      assert {:ok, deleted} = delete_gateway(gateway, subject)
      assert deleted.deleted_at
    end

    test "returns error when subject has no permission to delete gateways", %{
      subject: subject
    } do
      gateway = GatewaysFixtures.create_gateway()

      subject = AuthFixtures.remove_permissions(subject)

      assert delete_gateway(gateway, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Gateways.Authorizer.manage_gateways_permission()]]}}
    end
  end

  describe "encode_token!/1" do
    test "returns encoded token" do
      token = GatewaysFixtures.create_token()
      assert encrypted_secret = encode_token!(token)

      config = Application.fetch_env!(:domain, Domain.Gateways)
      key_base = Keyword.fetch!(config, :key_base)
      salt = Keyword.fetch!(config, :salt)

      assert Plug.Crypto.verify(key_base, salt, encrypted_secret) ==
               {:ok, {token.id, token.value}}
    end
  end

  describe "authorize_gateway/1" do
    test "returns token when encoded secret is valid" do
      token = GatewaysFixtures.create_token()
      encoded_token = encode_token!(token)
      assert {:ok, fetched_token} = authorize_gateway(encoded_token)
      assert fetched_token.id == token.id
      assert is_nil(fetched_token.value)
    end

    test "returns error when secret is invalid" do
      assert authorize_gateway(Ecto.UUID.generate()) == {:error, :invalid_token}
    end
  end
end
