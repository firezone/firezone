defmodule Domain.ClientsTest do
  use Domain.DataCase, async: true
  import Domain.Clients
  alias Domain.Clients

  setup do
    account = Fixtures.Accounts.create_account()

    unprivileged_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)

    unprivileged_identity =
      Fixtures.Auth.create_identity(account: account, actor: unprivileged_actor)

    unprivileged_subject = Fixtures.Auth.create_subject(identity: unprivileged_identity)

    admin_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    admin_identity = Fixtures.Auth.create_identity(account: account, actor: admin_actor)
    admin_subject = Fixtures.Auth.create_subject(identity: admin_identity)

    %{
      account: account,
      unprivileged_actor: unprivileged_actor,
      unprivileged_identity: unprivileged_identity,
      unprivileged_subject: unprivileged_subject,
      admin_actor: admin_actor,
      admin_identity: admin_identity,
      admin_subject: admin_subject
    }
  end

  describe "count_by_account_id/0" do
    test "counts clients for an account", %{account: account} do
      Fixtures.Clients.create_client(account: account)
      Fixtures.Clients.create_client(account: account)
      Fixtures.Clients.create_client(account: account)
      Fixtures.Clients.create_client()

      assert count_by_account_id(account.id) == 3
    end
  end

  describe "count_1m_active_users_for_account/1" do
    test "returns 0 when there are no clients", %{account: account} do
      assert count_1m_active_users_for_account(account) == 0
    end

    test "returns 0 when there are no clients active within one month", %{account: account} do
      forty_days_ago = DateTime.utc_now() |> DateTime.add(-40, :day)
      client = Fixtures.Clients.create_client(account: account)
      client |> Ecto.Changeset.change(last_seen_at: forty_days_ago) |> Repo.update!()
      assert count_1m_active_users_for_account(account) == 0
    end

    test "filters inactive actors", %{account: account} do
      actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Clients.create_client(account: account, actor: actor)

      Fixtures.Actors.disable(actor)

      assert count_1m_active_users_for_account(account) == 0
    end

    test "filters non-user actors", %{account: account} do
      actor = Fixtures.Actors.create_actor(account: account, type: :service_account)
      Fixtures.Clients.create_client(account: account, actor: actor)
      assert count_1m_active_users_for_account(account) == 0
    end

    test "counts distinct actor ids in an account", %{account: account} do
      actor1 = Fixtures.Actors.create_actor(account: account)
      actor2 = Fixtures.Actors.create_actor(account: account)

      Fixtures.Clients.create_client(account: account, actor: actor1)
      Fixtures.Clients.create_client(account: account, actor: actor1)
      Fixtures.Clients.create_client(account: account, actor: actor2)
      Fixtures.Clients.create_client()

      assert count_1m_active_users_for_account(account) == 2
    end
  end

  describe "count_by_actor_id/1" do
    test "returns 0 if actor does not exist" do
      assert count_by_actor_id(Ecto.UUID.generate()) == 0
    end

    test "returns count of clients for a actor" do
      client = Fixtures.Clients.create_client()
      assert count_by_actor_id(client.actor_id) == 1
    end
  end

  describe "fetch_client_by_id/3" do
    test "returns error when UUID is invalid", %{unprivileged_subject: subject} do
      assert fetch_client_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns deleted clients", %{
      unprivileged_actor: actor,
      unprivileged_subject: subject
    } do
      client =
        Fixtures.Clients.create_client(actor: actor)
        |> Fixtures.Clients.delete_client()

      assert {:ok, _client} = fetch_client_by_id(client.id, subject)
    end

    test "returns client by id", %{unprivileged_actor: actor, unprivileged_subject: subject} do
      client = Fixtures.Clients.create_client(actor: actor)
      assert fetch_client_by_id(client.id, subject, preload: [:online?]) == {:ok, client}
    end

    test "preloads online status", %{unprivileged_actor: actor, unprivileged_subject: subject} do
      client = Fixtures.Clients.create_client(actor: actor)

      assert {:ok, client} = fetch_client_by_id(client.id, subject, preload: [:online?])
      assert client.online? == false

      assert connect_client(client) == :ok
      assert {:ok, client} = fetch_client_by_id(client.id, subject, preload: [:online?])
      assert client.online? == true
    end

    test "returns client that belongs to another actor with manage permission", %{
      account: account,
      unprivileged_subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account)

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.add_permission(Clients.Authorizer.manage_clients_permission())

      assert fetch_client_by_id(client.id, subject, preload: [:online?]) == {:ok, client}
    end

    test "does not returns client that belongs to another account with manage permission", %{
      unprivileged_subject: subject
    } do
      client = Fixtures.Clients.create_client()

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.add_permission(Clients.Authorizer.manage_clients_permission())

      assert fetch_client_by_id(client.id, subject) == {:error, :not_found}
    end

    test "does not return client that belongs to another actor with manage_own permission", %{
      unprivileged_subject: subject
    } do
      client = Fixtures.Clients.create_client()

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.add_permission(Clients.Authorizer.manage_own_clients_permission())

      assert fetch_client_by_id(client.id, subject) == {:error, :not_found}
    end

    test "returns error when client does not exist", %{unprivileged_subject: subject} do
      assert fetch_client_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view clients", %{
      unprivileged_subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_client_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Clients.Authorizer.manage_clients_permission(),
                      Clients.Authorizer.manage_own_clients_permission()
                    ]}
                 ]}}
    end
  end

  describe "fetch_client_by_id!/2" do
    test "raises when UUID is invalid" do
      assert_raise Ecto.Query.CastError, fn ->
        fetch_client_by_id!("foo")
      end
    end

    test "raises when client does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        fetch_client_by_id!(Ecto.UUID.generate())
      end
    end

    test "raises when client is deleted", %{
      unprivileged_actor: actor
    } do
      client =
        Fixtures.Clients.create_client(actor: actor)
        |> Fixtures.Clients.delete_client()

      assert_raise Ecto.NoResultsError, fn ->
        fetch_client_by_id!(client.id)
      end
    end

    test "returns client by id", %{unprivileged_actor: actor} do
      client = Fixtures.Clients.create_client(actor: actor)
      assert fetch_client_by_id!(client.id, preload: [:online?]) == client
    end

    test "preloads online status", %{unprivileged_actor: actor} do
      client = Fixtures.Clients.create_client(actor: actor)

      assert client = fetch_client_by_id!(client.id, preload: [:online?])
      assert client.online? == false

      assert connect_client(client) == :ok
      assert client = fetch_client_by_id!(client.id, preload: [:online?])
      assert client.online? == true
    end
  end

  describe "list_clients/1" do
    test "returns empty list when there are no clients", %{admin_subject: subject} do
      assert {:ok, [], _metadata} = list_clients(subject)
    end

    test "does not list deleted clients", %{
      unprivileged_actor: actor,
      unprivileged_subject: subject
    } do
      Fixtures.Clients.create_client(actor: actor)
      |> Fixtures.Clients.delete_client()

      assert {:ok, [], _metadata} = list_clients(subject)
    end

    test "does not list  clients in other accounts", %{
      unprivileged_subject: subject
    } do
      Fixtures.Clients.create_client()

      assert {:ok, [], _metadata} = list_clients(subject)
    end

    test "shows all clients owned by a actor for unprivileged subject", %{
      unprivileged_actor: actor,
      admin_actor: other_actor,
      unprivileged_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)
      Fixtures.Clients.create_client(actor: other_actor)

      assert {:ok, [fetched_client], _metadata} = list_clients(subject)
      assert fetched_client.id == client.id
    end

    test "shows all clients for admin subject", %{
      unprivileged_actor: other_actor,
      admin_actor: admin_actor,
      admin_subject: subject
    } do
      Fixtures.Clients.create_client(actor: admin_actor)
      Fixtures.Clients.create_client(actor: other_actor)

      assert {:ok, clients, _metadata} = list_clients(subject)
      assert length(clients) == 2
    end

    test "preloads online status", %{unprivileged_actor: actor, unprivileged_subject: subject} do
      Fixtures.Clients.create_client(actor: actor)

      assert {:ok, [client], _metadata} = list_clients(subject, preload: [:online?])
      assert client.online? == false

      assert connect_client(client) == :ok
      assert {:ok, [client], _metadata} = list_clients(subject, preload: [:online?])
      assert client.online? == true
    end

    test "returns error when subject has no permission to manage clients", %{
      unprivileged_subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_clients(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Clients.Authorizer.manage_clients_permission(),
                      Clients.Authorizer.manage_own_clients_permission()
                    ]}
                 ]}}
    end
  end

  describe "list_clients_by_actor_id/2" do
    test "returns empty list when there are no clients for a given actor", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      assert {:ok, [], _metadata} = list_clients_by_actor_id(Ecto.UUID.generate(), subject)
      assert {:ok, [], _metadata} = list_clients_by_actor_id(actor.id, subject)
      Fixtures.Clients.create_client()
      assert {:ok, [], _metadata} = list_clients_by_actor_id(actor.id, subject)
    end

    test "returns empty list when actor id is invalid", %{admin_subject: subject} do
      assert {:ok, [], _metadata} = list_clients_by_actor_id("foo", subject)
    end

    test "does not list deleted clients", %{
      unprivileged_actor: actor,
      unprivileged_identity: identity,
      unprivileged_subject: subject
    } do
      Fixtures.Clients.create_client(identity: identity)
      |> Fixtures.Clients.delete_client()

      assert {:ok, [], _metadata} = list_clients_by_actor_id(actor.id, subject)
    end

    test "does not deleted clients for actors in other accounts", %{
      unprivileged_subject: unprivileged_subject,
      admin_subject: admin_subject
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user)
      Fixtures.Clients.create_client(actor: actor)

      assert {:ok, [], _metadata} = list_clients_by_actor_id(actor.id, unprivileged_subject)
      assert {:ok, [], _metadata} = list_clients_by_actor_id(actor.id, admin_subject)
    end

    test "shows only clients owned by a actor for unprivileged subject", %{
      unprivileged_actor: actor,
      admin_actor: other_actor,
      unprivileged_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)
      Fixtures.Clients.create_client(actor: other_actor)

      assert {:ok, [^client], _metadata} =
               list_clients_by_actor_id(actor.id, subject, preload: [:online?])

      assert {:ok, [], _metadata} = list_clients_by_actor_id(other_actor.id, subject)
    end

    test "shows all clients owned by another actor for admin subject", %{
      unprivileged_actor: other_actor,
      admin_actor: admin_actor,
      admin_subject: subject
    } do
      Fixtures.Clients.create_client(actor: admin_actor)
      Fixtures.Clients.create_client(actor: other_actor)

      assert {:ok, [_client], _metadata} = list_clients_by_actor_id(admin_actor.id, subject)
      assert {:ok, [_client], _metadata} = list_clients_by_actor_id(other_actor.id, subject)
    end

    test "returns error when subject has no permission to manage clients", %{
      unprivileged_subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_clients_by_actor_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [
                   reason: :missing_permissions,
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
    test "returns changeset with given changes", %{admin_actor: actor} do
      client = Fixtures.Clients.create_client(actor: actor)
      client_attrs = Fixtures.Clients.client_attrs()

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
        ipv4: "1.1.1.256",
        ipv6: "fd01::10000"
      }

      assert {:error, changeset} = upsert_client(attrs, subject)

      assert errors_on(changeset) == %{
               public_key: ["should be 44 character(s)", "must be a base64-encoded string"],
               external_id: ["can't be blank"]
             }
    end

    test "allows creating client with just required attributes", %{
      admin_actor: actor,
      admin_identity: identity,
      admin_subject: subject
    } do
      attrs =
        Fixtures.Clients.client_attrs()
        |> Map.delete(:name)

      assert {:ok, client} = upsert_client(attrs, subject)

      assert client.name

      assert client.public_key == attrs.public_key

      assert client.actor_id == actor.id
      assert client.identity_id == identity.id
      assert client.account_id == actor.account_id

      refute is_nil(client.ipv4)
      refute is_nil(client.ipv6)

      assert client.last_seen_remote_ip == %Postgrex.INET{address: subject.context.remote_ip}

      assert client.last_seen_remote_ip_location_region ==
               subject.context.remote_ip_location_region

      assert client.last_seen_remote_ip_location_city == subject.context.remote_ip_location_city
      assert client.last_seen_remote_ip_location_lat == subject.context.remote_ip_location_lat
      assert client.last_seen_remote_ip_location_lon == subject.context.remote_ip_location_lon

      assert client.last_seen_user_agent == subject.context.user_agent
      assert client.last_seen_version == "1.3.0"
      assert client.last_seen_at

      assert is_nil(client.verified_at)
    end

    test "updates client when it already exists", %{
      account: account,
      admin_actor: actor,
      admin_subject: subject
    } do
      previous_identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      previous_subject =
        Fixtures.Auth.create_subject(account: account, identity: previous_identity)

      client = Fixtures.Clients.create_client(subject: previous_subject)
      client = Fixtures.Clients.verify_client(client)

      attrs =
        Fixtures.Clients.client_attrs(
          external_id: client.external_id,
          device_serial: client.device_serial,
          device_uuid: client.device_uuid,
          identifier_for_vendor: client.identifier_for_vendor,
          firebase_installation_id: client.firebase_installation_id
        )

      subject = %{
        subject
        | context: %Domain.Auth.Context{
            subject.context
            | remote_ip: {100, 64, 100, 101},
              remote_ip_location_region: "Mexico",
              remote_ip_location_city: "Merida",
              remote_ip_location_lat: 7.7758,
              remote_ip_location_lon: -2.4128,
              user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"
          }
      }

      assert {:ok, updated_client} = upsert_client(attrs, subject)

      assert Repo.aggregate(Clients.Client, :count, :id) == 1

      assert updated_client.name != client.name
      assert updated_client.last_seen_remote_ip.address == subject.context.remote_ip
      assert updated_client.last_seen_remote_ip != client.last_seen_remote_ip
      assert updated_client.last_seen_user_agent == subject.context.user_agent
      assert updated_client.last_seen_user_agent != client.last_seen_user_agent
      assert updated_client.last_seen_version == "0.7.411"
      assert updated_client.public_key != client.public_key
      assert updated_client.public_key == attrs.public_key

      assert updated_client.actor_id == client.actor_id
      assert updated_client.identity_id == subject.identity.id
      assert updated_client.identity_id != client.identity_id
      assert updated_client.ipv4 == client.ipv4
      assert updated_client.ipv6 == client.ipv6
      assert updated_client.last_seen_at
      assert updated_client.last_seen_at != client.last_seen_at

      assert updated_client.last_seen_remote_ip_location_region ==
               subject.context.remote_ip_location_region

      assert updated_client.last_seen_remote_ip_location_city ==
               subject.context.remote_ip_location_city

      assert updated_client.last_seen_remote_ip_location_lat ==
               subject.context.remote_ip_location_lat

      assert updated_client.last_seen_remote_ip_location_lon ==
               subject.context.remote_ip_location_lon

      assert updated_client.verified_at == client.verified_at
      assert updated_client.verified_by == client.verified_by
      assert updated_client.verified_by_actor_id == client.verified_by_actor_id
      assert updated_client.verified_by_identity_id == client.verified_by_identity_id

      assert updated_client.device_serial == client.device_serial
      assert updated_client.device_uuid == client.device_uuid
      assert updated_client.identifier_for_vendor == client.identifier_for_vendor
      assert updated_client.firebase_installation_id == client.firebase_installation_id
    end

    test "creates a new client when external_id is changed", %{
      account: account,
      admin_actor: actor,
      admin_subject: subject
    } do
      previous_identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      previous_subject =
        Fixtures.Auth.create_subject(account: account, identity: previous_identity)

      client = Fixtures.Clients.create_client(subject: previous_subject)

      attrs =
        Fixtures.Clients.client_attrs(
          external_id: Ecto.UUID.generate(),
          device_serial: client.device_serial,
          device_uuid: client.device_uuid,
          identifier_for_vendor: client.identifier_for_vendor,
          firebase_installation_id: client.firebase_installation_id
        )

      subject = %{
        subject
        | context: %Domain.Auth.Context{
            subject.context
            | remote_ip: {100, 64, 100, 101},
              remote_ip_location_region: "Mexico",
              remote_ip_location_city: "Merida",
              remote_ip_location_lat: 7.7758,
              remote_ip_location_lon: -2.4128,
              user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"
          }
      }

      assert {:ok, created_client} = upsert_client(attrs, subject)
      assert created_client.id != client.id

      assert Repo.aggregate(Clients.Client, :count, :id) == 2

      assert created_client.name == attrs.name
      assert created_client.last_seen_remote_ip.address == subject.context.remote_ip
      assert created_client.last_seen_user_agent == subject.context.user_agent
      assert created_client.last_seen_version == "0.7.411"
      assert created_client.public_key == attrs.public_key

      assert created_client.actor_id == client.actor_id
      assert created_client.identity_id == subject.identity.id
      assert created_client.ipv4 != client.ipv4
      assert created_client.ipv6 != client.ipv6
      assert created_client.last_seen_at

      assert created_client.last_seen_remote_ip_location_region ==
               subject.context.remote_ip_location_region

      assert created_client.last_seen_remote_ip_location_city ==
               subject.context.remote_ip_location_city

      assert created_client.last_seen_remote_ip_location_lat ==
               subject.context.remote_ip_location_lat

      assert created_client.last_seen_remote_ip_location_lon ==
               subject.context.remote_ip_location_lon

      refute created_client.verified_at
      refute created_client.verified_by
      refute created_client.verified_by_actor_id
      refute created_client.verified_by_identity_id

      assert created_client.device_serial == attrs.device_serial
      assert created_client.device_uuid == attrs.device_uuid
      assert created_client.identifier_for_vendor == attrs.identifier_for_vendor
      assert created_client.firebase_installation_id == attrs.firebase_installation_id
    end

    test "resets the verification when any of the hardware ids is changed", %{
      account: account,
      admin_actor: actor,
      admin_subject: subject
    } do
      previous_identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      previous_subject =
        Fixtures.Auth.create_subject(account: account, identity: previous_identity)

      subject = %{
        subject
        | context: %Domain.Auth.Context{
            subject.context
            | remote_ip: {100, 64, 100, 101},
              remote_ip_location_region: "Mexico",
              remote_ip_location_city: "Merida",
              remote_ip_location_lat: 7.7758,
              remote_ip_location_lon: -2.4128,
              user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"
          }
      }

      for field <- [
            :device_serial,
            :device_uuid,
            :identifier_for_vendor,
            :firebase_installation_id
          ] do
        client = Fixtures.Clients.create_client(subject: previous_subject)
        client = Fixtures.Clients.verify_client(client)

        attrs =
          Fixtures.Clients.client_attrs(
            external_id: client.external_id,
            device_serial: client.device_serial,
            device_uuid: client.device_uuid,
            identifier_for_vendor: client.identifier_for_vendor,
            firebase_installation_id: client.firebase_installation_id
          )

        attrs = Map.put(attrs, field, Ecto.UUID.generate())
        assert {:ok, updated_client} = upsert_client(attrs, subject)
        assert updated_client.id == client.id
        assert Map.get(updated_client, field) == Map.get(attrs, field)

        assert is_nil(updated_client.verified_at)
        assert is_nil(updated_client.verified_by)
        assert is_nil(updated_client.verified_by_actor_id)
        assert is_nil(updated_client.verified_by_identity_id)
      end
    end

    test "resets the verification when any of the hardware ids is nilified", %{
      account: account,
      admin_actor: actor,
      admin_subject: subject
    } do
      previous_identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      previous_subject =
        Fixtures.Auth.create_subject(account: account, identity: previous_identity)

      subject = %{
        subject
        | context: %Domain.Auth.Context{
            subject.context
            | remote_ip: {100, 64, 100, 101},
              remote_ip_location_region: "Mexico",
              remote_ip_location_city: "Merida",
              remote_ip_location_lat: 7.7758,
              remote_ip_location_lon: -2.4128,
              user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"
          }
      }

      for field <- [
            :device_serial,
            :device_uuid,
            :identifier_for_vendor,
            :firebase_installation_id
          ] do
        client = Fixtures.Clients.create_client(subject: previous_subject)
        client = Fixtures.Clients.verify_client(client)

        attrs =
          Fixtures.Clients.client_attrs(
            external_id: client.external_id,
            device_serial: client.device_serial,
            device_uuid: client.device_uuid,
            identifier_for_vendor: client.identifier_for_vendor,
            firebase_installation_id: client.firebase_installation_id
          )

        attrs = Map.put(attrs, field, nil)
        assert {:ok, updated_client} = upsert_client(attrs, subject)
        assert updated_client.id == client.id
        refute Map.get(updated_client, field)

        assert is_nil(updated_client.verified_at)
        assert is_nil(updated_client.verified_by)
        assert is_nil(updated_client.verified_by_actor_id)
        assert is_nil(updated_client.verified_by_identity_id)
      end
    end

    test "does not reset the verification when a new hardware id is added", %{
      account: account,
      admin_actor: actor,
      admin_subject: subject
    } do
      previous_identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      previous_subject =
        Fixtures.Auth.create_subject(account: account, identity: previous_identity)

      subject = %{
        subject
        | context: %Domain.Auth.Context{
            subject.context
            | remote_ip: {100, 64, 100, 101},
              remote_ip_location_region: "Mexico",
              remote_ip_location_city: "Merida",
              remote_ip_location_lat: 7.7758,
              remote_ip_location_lon: -2.4128,
              user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"
          }
      }

      client =
        Fixtures.Clients.create_client(
          subject: previous_subject,
          device_serial: nil,
          device_uuid: nil,
          identifier_for_vendor: nil,
          firebase_installation_id: nil
        )

      client = Fixtures.Clients.verify_client(client)
      attrs = Fixtures.Clients.client_attrs(external_id: client.external_id)

      assert {:ok, updated_client} = upsert_client(attrs, subject)
      assert updated_client.id == client.id

      assert updated_client.device_serial == attrs.device_serial
      assert updated_client.device_uuid == attrs.device_uuid
      assert updated_client.identifier_for_vendor == attrs.identifier_for_vendor
      assert updated_client.firebase_installation_id == attrs.firebase_installation_id

      refute is_nil(updated_client.verified_at)
      refute is_nil(updated_client.verified_by)
      refute is_nil(updated_client.verified_by_actor_id)
      refute is_nil(updated_client.verified_by_identity_id)
    end

    test "does not reserve additional addresses on update", %{
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(subject: subject)

      attrs =
        Fixtures.Clients.client_attrs(
          external_id: client.external_id,
          device_serial: client.device_serial,
          device_uuid: client.device_uuid,
          identifier_for_vendor: client.identifier_for_vendor,
          firebase_installation_id: client.firebase_installation_id,
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

    test "allows unprivileged actor to create a client for himself", %{
      admin_subject: subject
    } do
      attrs =
        Fixtures.Clients.client_attrs()
        |> Map.delete(:name)

      assert {:ok, _client} = upsert_client(attrs, subject)
    end

    test "allows an actor to have multiple devices with the same name", %{
      admin_subject: subject
    } do
      name = Ecto.UUID.generate()

      attrs = Fixtures.Clients.client_attrs(name: name)
      assert {:ok, client1} = upsert_client(attrs, subject)

      attrs = Fixtures.Clients.client_attrs(name: name)
      assert {:ok, client2} = upsert_client(attrs, subject)

      assert client1.name == client2.name
      assert client1.id != client2.id
    end

    test "allows service account to create a client for self", %{account: account} do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor)
      attrs = Fixtures.Clients.client_attrs()

      assert {:ok, client} = upsert_client(attrs, subject)
      assert client.actor_id == subject.actor.id
      assert client.account_id == account.id
      refute client.identity_id
      assert is_nil(client.verified_at)
    end

    test "does not allow to reuse IP addresses", %{
      account: account,
      admin_subject: subject
    } do
      attrs = Fixtures.Clients.client_attrs(account: account)
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
        Fixtures.Network.create_address(address: client.ipv4, account: account)
      end

      assert_raise Ecto.ConstraintError, fn ->
        Fixtures.Network.create_address(address: client.ipv6, account: account)
      end
    end

    test "ip addresses are unique per account", %{
      account: account,
      admin_subject: subject
    } do
      attrs = Fixtures.Clients.client_attrs(account: account)
      assert {:ok, client} = upsert_client(attrs, subject)

      assert %Domain.Network.Address{} = Fixtures.Network.create_address(address: client.ipv4)
      assert %Domain.Network.Address{} = Fixtures.Network.create_address(address: client.ipv6)
    end

    test "returns error when subject has no permission to create clients", %{
      admin_subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert upsert_client(%{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.manage_own_clients_permission()]}}
    end
  end

  describe "update_client/3" do
    test "allows admin actor to update own clients", %{admin_actor: actor, admin_subject: subject} do
      client = Fixtures.Clients.create_client(actor: actor)
      attrs = %{name: "new name"}

      assert {:ok, client} = update_client(client, attrs, subject)

      assert client.name == attrs.name
    end

    test "allows admin actor to update other actors clients", %{
      account: account,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account)
      attrs = %{name: "new name"}

      assert {:ok, client} = update_client(client, attrs, subject)

      assert client.name == attrs.name
    end

    test "allows unprivileged actor to update own clients", %{
      unprivileged_actor: actor,
      unprivileged_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)
      :ok = Domain.PubSub.subscribe("clients:#{client.id}")

      attrs = %{name: "new name"}

      assert {:ok, client} = update_client(client, attrs, subject)

      assert client.name == attrs.name

      assert_receive :updated
    end

    test "does not allow unprivileged actor to update other actors clients", %{
      account: account,
      unprivileged_subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account)
      attrs = %{name: "new name"}

      assert update_client(client, attrs, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.manage_clients_permission()]}}
    end

    test "does not allow admin actor to update clients in other accounts", %{
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client()
      attrs = %{name: "new name"}

      assert update_client(client, attrs, subject) == {:error, :not_found}
    end

    test "does not allow to reset required fields to empty values", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)
      attrs = %{name: nil, public_key: nil}

      assert {:error, changeset} = update_client(client, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{admin_actor: actor, admin_subject: subject} do
      client = Fixtures.Clients.create_client(actor: actor)

      attrs = %{
        name: String.duplicate("a", 256)
      }

      assert {:error, changeset} = update_client(client, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"]
             }
    end

    test "ignores updates for any field except name", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)

      fields = Clients.Client.__schema__(:fields) -- [:name]
      value = -1

      for field <- fields do
        assert {:ok, updated_client} = update_client(client, %{field => value}, subject)
        assert updated_client == client
      end
    end

    test "returns error when subject has no permission to update clients", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)

      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_client(client, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.manage_own_clients_permission()]}}

      client = Fixtures.Clients.create_client()

      assert update_client(client, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.manage_clients_permission()]}}
    end
  end

  describe "verify_client/2" do
    test "allows admin actor to verify clients", %{admin_actor: actor, admin_subject: subject} do
      client = Fixtures.Clients.create_client(actor: actor)
      :ok = Domain.PubSub.subscribe("clients:#{client.id}")

      assert {:ok, client} = verify_client(client, subject)
      assert client.verified_at
      assert client.verified_by == :identity
      assert client.verified_by_actor_id == subject.actor.id
      assert client.verified_by_identity_id == subject.identity.id

      assert_receive :updated

      assert {:ok, double_verified_client} = verify_client(client, subject)
      assert double_verified_client.verified_at == client.verified_at
    end

    test "returns error when subject has no permission to verify clients", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)

      subject =
        Fixtures.Auth.remove_permission(
          subject,
          Clients.Authorizer.verify_clients_permission()
        )

      assert verify_client(client, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.verify_clients_permission()]}}
    end
  end

  describe "remove_client_verification/2" do
    test "allows admin actor to remove client verification", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)
      :ok = Domain.PubSub.subscribe("clients:#{client.id}")

      assert {:ok, client} = verify_client(client, subject)
      assert {:ok, client} = remove_client_verification(client, subject)

      assert is_nil(client.verified_at)
      assert is_nil(client.verified_by)
      assert is_nil(client.verified_by_actor_id)
      assert is_nil(client.verified_by_identity_id)

      assert_receive :updated
    end

    test "expires flows for the unverified client", %{
      account: account,
      admin_actor: actor,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          actor: actor,
          client: client,
          subject: subject
        )

      :ok = Domain.Flows.subscribe_to_flow_expiration_events(flow)

      assert {:ok, client} = verify_client(client, subject)
      assert {:ok, client} = remove_client_verification(client, subject)

      assert_received {:expire_flow, flow_id, flow_client_id, _flow_resource_id}
      assert flow_id == flow.id
      assert flow_client_id == client.id
    end

    test "returns error when subject has no permission to verify clients", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)

      subject =
        Fixtures.Auth.remove_permission(
          subject,
          Clients.Authorizer.verify_clients_permission()
        )

      assert remove_client_verification(client, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.verify_clients_permission()]}}
    end
  end

  describe "delete_client/2" do
    test "returns error on state conflict", %{admin_actor: actor, admin_subject: subject} do
      client = Fixtures.Clients.create_client(actor: actor)

      assert {:ok, deleted} = delete_client(client, subject)
      assert delete_client(deleted, subject) == {:error, :not_found}
      assert delete_client(client, subject) == {:error, :not_found}
    end

    test "admin can delete own clients", %{admin_actor: actor, admin_subject: subject} do
      client = Fixtures.Clients.create_client(actor: actor)

      assert {:ok, deleted} = delete_client(client, subject)
      assert deleted.deleted_at
    end

    test "admin can delete other people clients", %{
      unprivileged_actor: actor,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)

      assert {:ok, deleted} = delete_client(client, subject)
      assert deleted.deleted_at
    end

    test "admin cannot delete clients in other accounts", %{
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client()

      assert delete_client(client, subject) == {:error, :not_found}
    end

    test "unprivileged can delete own clients", %{
      account: account,
      unprivileged_actor: actor,
      unprivileged_subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, actor: actor)

      assert {:ok, deleted} = delete_client(client, subject)
      assert deleted.deleted_at
    end

    test "unprivileged cannot delete other people clients", %{
      account: account,
      unprivileged_subject: subject
    } do
      client = Fixtures.Clients.create_client()

      assert delete_client(client, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.manage_clients_permission()]}}

      client = Fixtures.Clients.create_client(account: account)

      assert delete_client(client, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.manage_clients_permission()]}}

      assert Repo.aggregate(Clients.Client, :count) == 2
    end

    test "returns error when subject has no permission to delete clients", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      client = Fixtures.Clients.create_client(actor: actor)

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_client(client, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.manage_own_clients_permission()]}}

      client = Fixtures.Clients.create_client()

      assert delete_client(client, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.manage_clients_permission()]}}
    end
  end

  describe "delete_clients_for/2" do
    test "removes all clients that belong to an actor", %{
      account: account,
      admin_subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Clients.create_client(actor: actor)
      Fixtures.Clients.create_client(actor: actor)
      Fixtures.Clients.create_client(actor: actor)

      query =
        Clients.Client.Query.not_deleted()
        |> Clients.Client.Query.by_actor_id(actor.id)

      assert Repo.aggregate(query, :count) == 3
      assert delete_clients_for(actor, subject) == :ok
      assert Repo.aggregate(query, :count) == 0
    end

    test "does not remove clients that belong to another actor", %{
      account: account,
      admin_subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Clients.create_client()

      assert delete_clients_for(actor, subject) == :ok
      assert Repo.aggregate(Clients.Client.Query.all(), :count) == 1
    end

    test "doesn't allow regular user to delete other user's clients", %{
      unprivileged_subject: subject
    } do
      actor = Fixtures.Actors.create_actor()
      Fixtures.Clients.create_client(actor: actor)

      assert delete_clients_for(actor, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Clients.Authorizer.manage_clients_permission()]}}
    end
  end

  describe "connect_client/1" do
    test "tracks client presence for account", %{account: account} do
      client = Fixtures.Clients.create_client(account: account)
      assert connect_client(client) == :ok

      client = fetch_client_by_id!(client.id, preload: [:online?])
      assert client.online? == true
    end

    test "tracks client presence for actor", %{account: account} do
      actor = Fixtures.Actors.create_actor(account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      assert connect_client(client) == :ok

      assert broadcast_to_client(client, "test") == :ok

      assert_receive "test"
    end

    test "subscribes to client events", %{account: account} do
      actor = Fixtures.Actors.create_actor(account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      assert connect_client(client) == :ok

      assert disconnect_client(client) == :ok

      assert_receive "disconnect"
    end

    test "subscribes to account events", %{account: account} do
      actor = Fixtures.Actors.create_actor(account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)

      assert connect_client(client) == :ok

      assert disconnect_account_clients(account) == :ok

      assert_receive "disconnect"
    end
  end
end
