defmodule Domain.ClientsTest do
  use Domain.DataCase, async: true
  import Domain.Clients
  alias Domain.{NetworkFixtures, UsersFixtures, SubjectFixtures, ClientsFixtures}
  alias Domain.Clients

  setup do
    unprivileged_user = UsersFixtures.create_user_with_role(:unprivileged)
    unprivileged_subject = SubjectFixtures.create_subject(unprivileged_user)

    admin_user = UsersFixtures.create_user_with_role(:admin)
    admin_subject = SubjectFixtures.create_subject(admin_user)

    %{
      unprivileged_user: unprivileged_user,
      unprivileged_subject: unprivileged_subject,
      admin_user: admin_user,
      admin_subject: admin_subject
    }
  end

  describe "count/0" do
    test "counts clients" do
      ClientsFixtures.create_client()
      ClientsFixtures.create_client()
      ClientsFixtures.create_client()
      assert count() == 3
    end
  end

  describe "count_by_user_id/1" do
    test "returns 0 if user does not exist" do
      assert count_by_user_id(Ecto.UUID.generate()) == 0
    end

    test "returns count of clients for a user" do
      client = ClientsFixtures.create_client()
      assert count_by_user_id(client.user_id) == 1
    end
  end

  describe "fetch_client_by_id/2" do
    test "returns error when UUID is invalid", %{unprivileged_subject: subject} do
      assert fetch_client_by_id("foo", subject) == {:error, :not_found}
    end

    test "does not return deleted clients", %{
      unprivileged_user: user,
      unprivileged_subject: subject
    } do
      client =
        ClientsFixtures.create_client(user: user)
        |> ClientsFixtures.delete_client()

      assert fetch_client_by_id(client.id, subject) == {:error, :not_found}
    end

    test "returns client by id", %{unprivileged_user: user, unprivileged_subject: subject} do
      client = ClientsFixtures.create_client(user: user)
      assert fetch_client_by_id(client.id, subject) == {:ok, client}
    end

    test "returns client that belongs to another user with manage permission", %{
      unprivileged_subject: subject
    } do
      client = ClientsFixtures.create_client()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Clients.Authorizer.manage_clients_permission())

      assert fetch_client_by_id(client.id, subject) == {:ok, client}
    end

    test "does not return client that belongs to another user with manage_own permission", %{
      unprivileged_subject: subject
    } do
      client = ClientsFixtures.create_client()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Clients.Authorizer.manage_own_clients_permission())

      assert fetch_client_by_id(client.id, subject) == {:error, :not_found}
    end

    test "returns error when client does not exist", %{unprivileged_subject: subject} do
      assert fetch_client_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view clients", %{
      unprivileged_subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_client_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Clients.Authorizer.manage_clients_permission(),
                        Clients.Authorizer.manage_own_clients_permission()
                      ]}
                   ]
                 ]}}
    end
  end

  describe "list_clients/1" do
    test "returns empty list when there are no clients", %{admin_subject: subject} do
      assert list_clients(subject) == {:ok, []}
    end

    test "does not list deleted clients", %{
      unprivileged_user: user,
      unprivileged_subject: subject
    } do
      ClientsFixtures.create_client(user: user)
      |> ClientsFixtures.delete_client()

      assert list_clients(subject) == {:ok, []}
    end

    test "shows all clients owned by a user for unprivileged subject", %{
      unprivileged_user: user,
      admin_user: other_user,
      unprivileged_subject: subject
    } do
      client = ClientsFixtures.create_client(user: user)
      ClientsFixtures.create_client(user: other_user)

      assert list_clients(subject) == {:ok, [client]}
    end

    test "shows all clients for admin subject", %{
      unprivileged_user: other_user,
      admin_user: admin_user,
      admin_subject: subject
    } do
      ClientsFixtures.create_client(user: admin_user)
      ClientsFixtures.create_client(user: other_user)

      assert {:ok, clients} = list_clients(subject)
      assert length(clients) == 2
    end

    test "returns error when subject has no permission to manage clients", %{
      unprivileged_subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_clients(subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Clients.Authorizer.manage_clients_permission(),
                        Clients.Authorizer.manage_own_clients_permission()
                      ]}
                   ]
                 ]}}
    end
  end

  describe "list_clients_by_user_id/2" do
    test "returns empty list when there are no clients for a given user", %{
      admin_user: user,
      admin_subject: subject
    } do
      assert list_clients_by_user_id(Ecto.UUID.generate(), subject) == {:ok, []}
      assert list_clients_by_user_id(user.id, subject) == {:ok, []}
      ClientsFixtures.create_client()
      assert list_clients_by_user_id(user.id, subject) == {:ok, []}
    end

    test "returns error when user id is invalid", %{admin_subject: subject} do
      assert list_clients_by_user_id("foo", subject) == {:error, :not_found}
    end

    test "does not list deleted clients", %{
      unprivileged_user: user,
      unprivileged_subject: subject
    } do
      ClientsFixtures.create_client(user: user)
      |> ClientsFixtures.delete_client()

      assert list_clients_by_user_id(user.id, subject) == {:ok, []}
    end

    test "shows only clients owned by a user for unprivileged subject", %{
      unprivileged_user: user,
      admin_user: other_user,
      unprivileged_subject: subject
    } do
      client = ClientsFixtures.create_client(user: user)
      ClientsFixtures.create_client(user: other_user)

      assert list_clients_by_user_id(user.id, subject) == {:ok, [client]}
      assert list_clients_by_user_id(other_user.id, subject) == {:ok, []}
    end

    test "shows all clients owned by another user for admin subject", %{
      unprivileged_user: other_user,
      admin_user: admin_user,
      admin_subject: subject
    } do
      ClientsFixtures.create_client(user: admin_user)
      ClientsFixtures.create_client(user: other_user)

      assert {:ok, [_client]} = list_clients_by_user_id(admin_user.id, subject)
      assert {:ok, [_client]} = list_clients_by_user_id(other_user.id, subject)
    end

    test "returns error when subject has no permission to manage clients", %{
      unprivileged_subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_clients_by_user_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Clients.Authorizer.manage_clients_permission(),
                        Clients.Authorizer.manage_own_clients_permission()
                      ]}
                   ]
                 ]}}
    end
  end

  describe "change_client/1" do
    test "returns changeset with given changes", %{admin_user: user} do
      client = ClientsFixtures.create_client(user: user)
      client_attrs = ClientsFixtures.client_attrs()

      assert changeset = change_client(client, client_attrs)
      assert %Ecto.Changeset{data: %Domain.Clients.Client{}} = changeset

      assert changeset.changes == %{name: client_attrs.name}
    end
  end

  describe "upsert_client/2" do
    test "returns errors on invalid attrs", %{
      admin_subject: subject
    } do
      attrs = %{
        external_id: nil,
        public_key: "x",
        preshared_key: "x",
        ipv4: "1.1.1.256",
        ipv6: "fd01::10000"
      }

      assert {:error, changeset} = upsert_client(attrs, subject)

      assert errors_on(changeset) == %{
               preshared_key: ["should be 44 character(s)", "must be a base64-encoded string"],
               public_key: ["should be 44 character(s)", "must be a base64-encoded string"],
               external_id: ["can't be blank"]
             }
    end

    test "allows creating client with just required attributes", %{
      admin_user: user,
      admin_subject: subject
    } do
      attrs =
        ClientsFixtures.client_attrs()
        |> Map.delete(:name)

      assert {:ok, client} = upsert_client(attrs, subject)

      assert client.name

      assert client.public_key == attrs.public_key
      assert client.preshared_key == attrs.preshared_key

      assert client.user_id == user.id

      refute is_nil(client.ipv4)
      refute is_nil(client.ipv6)

      assert client.last_seen_remote_ip == %Postgrex.INET{address: subject.context.remote_ip}
      assert client.last_seen_user_agent == subject.context.user_agent
      assert client.last_seen_version == "0.7.412"
      assert client.last_seen_at
    end

    test "updates client when it already exists", %{
      admin_subject: subject
    } do
      client = ClientsFixtures.create_client(subject: subject)
      attrs = ClientsFixtures.client_attrs(external_id: client.external_id)

      subject = %{
        subject
        | context: %Domain.Auth.Context{
            subject.context
            | remote_ip: {100, 64, 100, 101},
              user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"
          }
      }

      assert {:ok, updated_client} = upsert_client(attrs, subject)

      assert Repo.aggregate(Clients.Client, :count, :id) == 1

      assert updated_client.name
      assert updated_client.last_seen_remote_ip.address == subject.context.remote_ip
      assert updated_client.last_seen_remote_ip != client.last_seen_remote_ip
      assert updated_client.last_seen_user_agent == subject.context.user_agent
      assert updated_client.last_seen_user_agent != client.last_seen_user_agent
      assert updated_client.last_seen_version == "0.7.411"
      assert updated_client.public_key != client.public_key
      assert updated_client.public_key == attrs.public_key
      assert updated_client.preshared_key != client.preshared_key
      assert updated_client.preshared_key == attrs.preshared_key

      assert updated_client.user_id == client.user_id
      assert updated_client.ipv4 == client.ipv4
      assert updated_client.ipv6 == client.ipv6
      assert updated_client.last_seen_at
      assert updated_client.last_seen_at != client.last_seen_at
    end

    test "does not reserve additional addresses on update", %{
      admin_subject: subject
    } do
      client = ClientsFixtures.create_client(subject: subject)

      attrs =
        ClientsFixtures.client_attrs(
          external_id: client.external_id,
          last_seen_user_agent: "iOS/12.5 (iPhone) connlib/0.7.411",
          last_seen_remote_ip: %Postgrex.INET{address: {100, 64, 100, 100}}
        )

      assert {:ok, updated_client} = upsert_client(attrs, subject)

      addresses =
        Domain.Network.Address
        |> Repo.all()
        |> Enum.map(fn %Domain.Network.Address{address: address, type: type} ->
          %{address: address, type: type}
        end)

      assert length(addresses) == 2
      assert %{address: updated_client.ipv4, type: :ipv4} in addresses
      assert %{address: updated_client.ipv6, type: :ipv6} in addresses
    end

    test "allows unprivileged user to create a client for himself", %{
      admin_subject: subject
    } do
      attrs =
        ClientsFixtures.client_attrs()
        |> Map.delete(:name)

      assert {:ok, _client} = upsert_client(attrs, subject)
    end

    test "does not allow to reuse IP addresses", %{
      admin_subject: subject
    } do
      attrs = ClientsFixtures.client_attrs()
      assert {:ok, client} = upsert_client(attrs, subject)

      addresses =
        Domain.Network.Address
        |> Repo.all()
        |> Enum.map(fn %Domain.Network.Address{address: address, type: type} ->
          %{address: address, type: type}
        end)

      assert length(addresses) == 2
      assert %{address: client.ipv4, type: :ipv4} in addresses
      assert %{address: client.ipv6, type: :ipv6} in addresses

      assert_raise Ecto.ConstraintError, fn ->
        NetworkFixtures.create_address(address: client.ipv4)
      end
    end

    test "returns error when subject has no permission to create clients", %{
      admin_subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert upsert_client(%{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Clients.Authorizer.manage_own_clients_permission()]]}}
    end
  end

  describe "update_client/3" do
    test "allows admin user to update own clients", %{admin_user: user, admin_subject: subject} do
      client = ClientsFixtures.create_client(user: user)
      attrs = %{name: "new name"}

      assert {:ok, client} = update_client(client, attrs, subject)

      assert client.name == attrs.name
    end

    test "allows admin user to update other users clients", %{
      admin_subject: subject
    } do
      client = ClientsFixtures.create_client()
      attrs = %{name: "new name"}

      assert {:ok, client} = update_client(client, attrs, subject)

      assert client.name == attrs.name
    end

    test "allows unprivileged user to update own clients", %{
      unprivileged_user: user,
      unprivileged_subject: subject
    } do
      client = ClientsFixtures.create_client(user: user)
      attrs = %{name: "new name"}

      assert {:ok, client} = update_client(client, attrs, subject)

      assert client.name == attrs.name
    end

    test "does not allow unprivileged user to update other users clients", %{
      unprivileged_subject: subject
    } do
      client = ClientsFixtures.create_client()
      attrs = %{name: "new name"}

      assert update_client(client, attrs, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Clients.Authorizer.manage_clients_permission()]]}}
    end

    test "does not allow to reset required fields to empty values", %{
      admin_user: user,
      admin_subject: subject
    } do
      client = ClientsFixtures.create_client(user: user)
      attrs = %{name: nil, public_key: nil}

      assert {:error, changeset} = update_client(client, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{admin_user: user, admin_subject: subject} do
      client = ClientsFixtures.create_client(user: user)

      attrs = %{
        name: String.duplicate("a", 256)
      }

      assert {:error, changeset} = update_client(client, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"]
             }
    end

    test "ignores updates for any field except name", %{
      admin_user: user,
      admin_subject: subject
    } do
      client = ClientsFixtures.create_client(user: user)

      fields = Clients.Client.__schema__(:fields) -- [:name]
      value = -1

      for field <- fields do
        assert {:ok, updated_client} = update_client(client, %{field => value}, subject)
        assert updated_client == client
      end
    end

    test "returns error when subject has no permission to update clients", %{
      admin_user: user,
      admin_subject: subject
    } do
      client = ClientsFixtures.create_client(user: user)

      subject = SubjectFixtures.remove_permissions(subject)

      assert update_client(client, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Clients.Authorizer.manage_own_clients_permission()]]}}

      client = ClientsFixtures.create_client()

      assert update_client(client, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Clients.Authorizer.manage_clients_permission()]]}}
    end
  end

  describe "delete_client/2" do
    test "returns error on state conflict", %{admin_user: user, admin_subject: subject} do
      client = ClientsFixtures.create_client(user: user)

      assert {:ok, deleted} = delete_client(client, subject)
      assert delete_client(deleted, subject) == {:error, :not_found}
      assert delete_client(client, subject) == {:error, :not_found}
    end

    test "admin can delete own clients", %{admin_user: user, admin_subject: subject} do
      client = ClientsFixtures.create_client(user: user)

      assert {:ok, deleted} = delete_client(client, subject)
      assert deleted.deleted_at
    end

    test "admin can delete other people clients", %{
      unprivileged_user: user,
      admin_subject: subject
    } do
      client = ClientsFixtures.create_client(user: user)

      assert {:ok, deleted} = delete_client(client, subject)
      assert deleted.deleted_at
    end

    test "unprivileged can delete own clients", %{
      unprivileged_user: user,
      unprivileged_subject: subject
    } do
      client = ClientsFixtures.create_client(user: user)

      assert {:ok, deleted} = delete_client(client, subject)
      assert deleted.deleted_at
    end

    test "unprivileged can not delete other people clients", %{
      unprivileged_subject: subject
    } do
      client = ClientsFixtures.create_client()

      assert delete_client(client, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Clients.Authorizer.manage_clients_permission()]]}}

      assert Repo.aggregate(Clients.Client, :count) == 1
    end

    test "returns error when subject has no permission to delete clients", %{
      admin_user: user,
      admin_subject: subject
    } do
      client = ClientsFixtures.create_client(user: user)

      subject = SubjectFixtures.remove_permissions(subject)

      assert delete_client(client, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Clients.Authorizer.manage_own_clients_permission()]]}}

      client = ClientsFixtures.create_client()

      assert delete_client(client, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Clients.Authorizer.manage_clients_permission()]]}}
    end
  end

  describe "generate_name/1" do
    test "retains name with less than or equal to 15 chars" do
      assert generate_name("12345") == "12345"
      assert generate_name("1234567890ABCDE") == "1234567890ABCDE"
    end

    test "truncates long names that exceed 15 chars" do
      assert generate_name("1234567890ABCDEF") == "1234567890A4772"
    end
  end
end
