defmodule Domain.ResourcesTest do
  use Domain.DataCase, async: true
  import Domain.Resources
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures, GatewaysFixtures, NetworkFixtures}
  alias Domain.ResourcesFixtures
  alias Domain.Resources

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

  describe "fetch_resource_by_id/2" do
    test "returns error when resource does not exist", %{subject: subject} do
      assert fetch_resource_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_resource_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns resource when resource exists", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)
      resource = ResourcesFixtures.create_resource(account: account, gateway: gateway)

      assert {:ok, fetched_resource} = fetch_resource_by_id(resource.id, subject)
      assert fetched_resource.id == resource.id
    end

    test "does not return deleted resources", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)

      {:ok, resource} =
        ResourcesFixtures.create_resource(account: account, gateway: gateway)
        |> delete_resource(subject)

      assert fetch_resource_by_id(resource.id, subject) == {:error, :not_found}
    end

    test "does not return resources in other accounts", %{subject: subject} do
      resource = ResourcesFixtures.create_resource()
      assert fetch_resource_by_id(resource.id, subject) == {:error, :not_found}
    end

    test "returns error when subject has no permission to view resources", %{subject: subject} do
      subject = AuthFixtures.remove_permissions(subject)

      assert fetch_resource_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Resources.Authorizer.manage_resources_permission(),
                        Resources.Authorizer.view_available_resources_permission()
                      ]}
                   ]
                 ]}}
    end
  end

  describe "list_resources/1" do
    test "returns empty list when there are no resources", %{subject: subject} do
      assert list_resources(subject) == {:ok, []}
    end

    test "does not list resources from other accounts", %{
      subject: subject
    } do
      ResourcesFixtures.create_resource()
      assert list_resources(subject) == {:ok, []}
    end

    test "does not list deleted resources", %{
      account: account,
      subject: subject
    } do
      ResourcesFixtures.create_resource(account: account)
      |> delete_resource(subject)

      assert list_resources(subject) == {:ok, []}
    end

    test "returns all resources for account admin subject", %{
      account: account
    } do
      actor = ActorsFixtures.create_actor(type: :account_user, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      ResourcesFixtures.create_resource(account: account)
      ResourcesFixtures.create_resource(account: account)
      ResourcesFixtures.create_resource()

      assert {:ok, resources} = list_resources(subject)
      assert length(resources) == 2
    end

    test "returns all resources for account user subject", %{
      account: account,
      subject: subject
    } do
      ResourcesFixtures.create_resource(account: account)
      ResourcesFixtures.create_resource(account: account)
      ResourcesFixtures.create_resource()

      assert {:ok, resources} = list_resources(subject)
      assert length(resources) == 2
    end

    test "returns error when subject has no permission to manage resources", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert list_resources(subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Resources.Authorizer.manage_resources_permission(),
                        Resources.Authorizer.view_available_resources_permission()
                      ]}
                   ]
                 ]}}
    end
  end

  describe "create_resource/2" do
    test "returns changeset error on empty attrs", %{subject: subject} do
      assert {:error, changeset} = create_resource(%{}, subject)

      assert errors_on(changeset) == %{
               address: ["can't be blank"],
               connections: ["can't be blank"],
               type: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{subject: subject} do
      attrs = %{"name" => String.duplicate("a", 256), "filters" => :foo, "connections" => :bar}
      assert {:error, changeset} = create_resource(attrs, subject)

      assert errors_on(changeset) == %{
               address: ["can't be blank"],
               name: ["should be at most 255 character(s)"],
               filters: ["is invalid"],
               connections: ["is invalid"],
               type: ["can't be blank"]
             }
    end

    test "validates dns address", %{subject: subject} do
      attrs = %{"address" => String.duplicate("a", 256), "type" => "dns"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "should be at most 253 character(s)" in errors_on(changeset).address

      attrs = %{"address" => "a", "type" => "dns"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)
    end

    test "validates cidr address", %{subject: subject} do
      attrs = %{"address" => "192.168.1.256/28", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "is not a valid CIDR range" in errors_on(changeset).address

      attrs = %{"address" => "192.168.1.1", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "is not a valid CIDR range" in errors_on(changeset).address

      attrs = %{"address" => "100.64.0.0/8", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "can not be in the CIDR 100.64.0.0/10" in errors_on(changeset).address

      attrs = %{"address" => "fd00:2011:1111::/102", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "can not be in the CIDR fd00:2011:1111::/106" in errors_on(changeset).address

      attrs = %{"address" => "::/0", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)

      attrs = %{"address" => "0.0.0.0/0", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)
    end

    test "does not allow cidr addresses to overlap for the same account", %{
      account: account,
      subject: subject
    } do
      gateway = GatewaysFixtures.create_gateway(account: account)

      ResourcesFixtures.create_resource(
        account: account,
        subject: subject,
        type: :cidr,
        address: "192.168.1.1/28"
      )

      attrs = %{
        "address" => "192.168.1.8/26",
        "type" => "cidr",
        "connections" => [%{"gateway_id" => gateway.id}]
      }

      assert {:error, changeset} = create_resource(attrs, subject)
      assert "can not overlap with other resource ranges" in errors_on(changeset).address

      subject = AuthFixtures.create_subject()
      assert {:ok, _resource} = create_resource(attrs, subject)
    end

    test "returns error on duplicate name", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)
      resource = ResourcesFixtures.create_resource(account: account, subject: subject)
      address = ResourcesFixtures.resource_attrs().address

      attrs = %{
        "name" => resource.name,
        "address" => address,
        "type" => "dns",
        "connections" => [%{"gateway_id" => gateway.id}]
      }

      assert {:error, changeset} = create_resource(attrs, subject)
      assert errors_on(changeset) == %{name: ["has already been taken"]}
    end

    test "creates a dns resource", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)
      attrs = ResourcesFixtures.resource_attrs(connections: [%{gateway_id: gateway.id}])
      assert {:ok, resource} = create_resource(attrs, subject)

      assert resource.address == attrs.address
      assert resource.name == attrs.address
      assert resource.account_id == account.id

      refute is_nil(resource.ipv4)
      refute is_nil(resource.ipv6)

      assert [
               %Domain.Resources.Connection{
                 resource_id: resource_id,
                 gateway_id: gateway_id,
                 account_id: account_id
               }
             ] = resource.connections

      assert resource_id == resource.id
      assert gateway_id == gateway.id
      assert account_id == account.id

      assert [
               %Domain.Resources.Resource.Filter{ports: ["80", "433"], protocol: :tcp},
               %Domain.Resources.Resource.Filter{ports: ["100 - 200"], protocol: :udp}
             ] = resource.filters
    end

    test "creates a cidr resource", %{account: account, subject: subject} do
      gateway = GatewaysFixtures.create_gateway(account: account)
      address_count = Repo.aggregate(Domain.Network.Address, :count)

      attrs =
        ResourcesFixtures.resource_attrs(
          connections: [%{gateway_id: gateway.id}],
          type: :cidr,
          name: nil,
          address: "192.168.1.1/28"
        )

      assert {:ok, resource} = create_resource(attrs, subject)

      assert resource.address == "192.168.1.0/28"
      assert resource.name == attrs.address
      assert resource.account_id == account.id

      assert is_nil(resource.ipv4)
      assert is_nil(resource.ipv6)

      assert [
               %Domain.Resources.Connection{
                 resource_id: resource_id,
                 gateway_id: gateway_id,
                 account_id: account_id
               }
             ] = resource.connections

      assert resource_id == resource.id
      assert gateway_id == gateway.id
      assert account_id == account.id

      assert [
               %Domain.Resources.Resource.Filter{ports: ["80", "433"], protocol: :tcp},
               %Domain.Resources.Resource.Filter{ports: ["100 - 200"], protocol: :udp}
             ] = resource.filters

      assert Repo.aggregate(Domain.Network.Address, :count) == address_count
    end

    test "does not allow to reuse IP addresses within an account", %{
      account: account,
      subject: subject
    } do
      gateway = GatewaysFixtures.create_gateway(account: account)
      attrs = ResourcesFixtures.resource_attrs(connections: [%{gateway_id: gateway.id}])
      assert {:ok, resource} = create_resource(attrs, subject)

      addresses =
        Domain.Network.Address
        |> Repo.all()
        |> Enum.map(fn %Domain.Network.Address{address: address, type: type} ->
          %{address: address, type: type}
        end)

      assert %{address: resource.ipv4, type: :ipv4} in addresses
      assert %{address: resource.ipv6, type: :ipv6} in addresses

      assert_raise Ecto.ConstraintError, fn ->
        NetworkFixtures.create_address(address: resource.ipv4, account: account)
      end

      assert_raise Ecto.ConstraintError, fn ->
        NetworkFixtures.create_address(address: resource.ipv6, account: account)
      end
    end

    test "ip addresses are unique per account", %{
      account: account,
      subject: subject
    } do
      gateway = GatewaysFixtures.create_gateway(account: account)
      attrs = ResourcesFixtures.resource_attrs(connections: [%{gateway_id: gateway.id}])
      assert {:ok, resource} = create_resource(attrs, subject)

      assert %Domain.Network.Address{} = NetworkFixtures.create_address(address: resource.ipv4)
      assert %Domain.Network.Address{} = NetworkFixtures.create_address(address: resource.ipv6)
    end

    test "returns error when subject has no permission to create resources", %{
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert create_resource(%{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Resources.Authorizer.manage_resources_permission()]]}}
    end
  end

  describe "update_resource/3" do
    setup context do
      resource =
        ResourcesFixtures.create_resource(
          account: context.account,
          subject: context.subject
        )

      Map.put(context, :resource, resource)
    end

    test "does nothing on empty attrs", %{resource: resource, subject: subject} do
      assert {:ok, _resource} = update_resource(resource, %{}, subject)
    end

    test "returns error on invalid attrs", %{resource: resource, subject: subject} do
      attrs = %{"name" => String.duplicate("a", 256), "filters" => :foo, "connections" => :bar}
      assert {:error, changeset} = update_resource(resource, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"],
               filters: ["is invalid"],
               connections: ["is invalid"]
             }
    end

    test "allows to update name", %{resource: resource, subject: subject} do
      attrs = %{"name" => "foo"}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      assert resource.name == "foo"
    end

    test "allows to update filters", %{resource: resource, subject: subject} do
      attrs = %{"filters" => []}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      assert resource.filters == []
    end

    test "allows to update connections", %{account: account, resource: resource, subject: subject} do
      gateway1 = GatewaysFixtures.create_gateway(account: account)

      attrs = %{"connections" => [%{gateway_id: gateway1.id}]}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      gateway_ids = Enum.map(resource.connections, & &1.gateway_id)
      assert gateway_ids == [gateway1.id]

      gateway2 = GatewaysFixtures.create_gateway(account: account)
      attrs = %{"connections" => [%{gateway_id: gateway1.id}, %{gateway_id: gateway2.id}]}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      gateway_ids = Enum.map(resource.connections, & &1.gateway_id)
      assert Enum.sort(gateway_ids) == Enum.sort([gateway1.id, gateway2.id])

      attrs = %{"connections" => [%{gateway_id: gateway2.id}]}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      gateway_ids = Enum.map(resource.connections, & &1.gateway_id)
      assert gateway_ids == [gateway2.id]
    end

    test "does not allow to remove all connections", %{resource: resource, subject: subject} do
      attrs = %{"connections" => []}
      assert {:error, changeset} = update_resource(resource, attrs, subject)

      assert errors_on(changeset) == %{
               connections: ["can't be blank"]
             }
    end

    test "does not allow to update address", %{resource: resource, subject: subject} do
      attrs = %{"address" => "foo"}
      assert {:ok, updated_resource} = update_resource(resource, attrs, subject)
      assert updated_resource.address == resource.address
    end

    test "returns error when subject has no permission to create resources", %{
      resource: resource,
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert update_resource(resource, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Resources.Authorizer.manage_resources_permission()]]}}
    end
  end

  describe "delete_resource/2" do
    setup context do
      resource =
        ResourcesFixtures.create_resource(
          account: context.account,
          subject: context.subject
        )

      Map.put(context, :resource, resource)
    end

    test "returns error on state conflict", %{
      resource: resource,
      subject: subject
    } do
      assert {:ok, deleted} = delete_resource(resource, subject)
      assert delete_resource(deleted, subject) == {:error, :not_found}
      assert delete_resource(resource, subject) == {:error, :not_found}
    end

    test "deletes gateways", %{resource: resource, subject: subject} do
      assert {:ok, deleted} = delete_resource(resource, subject)
      assert deleted.deleted_at
    end

    test "returns error when subject has no permission to delete resources", %{
      resource: resource,
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert delete_resource(resource, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Resources.Authorizer.manage_resources_permission()]]}}
    end
  end
end
