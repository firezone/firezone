defmodule Portal.Queue.CallbacksTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias Portal.{Device, PG, PolicyAuthorization, SessionLog}

  describe "client session queue callback" do
    test "inserts client sessions and confirms durability" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)
      conn_id = make_ref()

      :ok = PG.register(client.id)

      attrs = %{
        conn_id: conn_id,
        account_id: account.id,
        device_id: client.id,
        client_token_id: token.id,
        public_key: generate_public_key(),
        user_agent: "test-client/1.0",
        remote_ip: {100, 64, 0, 1},
        remote_ip_location_region: "US",
        version: "1.3.0",
        inserted_at: DateTime.utc_now()
      }

      on_flush = Keyword.fetch!(PortalAPI.Client.Socket.client_session_queue_opts(), :on_flush)

      timestamp = DateTime.utc_now()
      subject = %{"actor_id" => actor.id, "actor_email" => actor.email}
      metadata = %{subject: subject, timestamp: timestamp}

      assert 1 = on_flush.([{attrs, metadata}])

      device = Repo.get_by!(Device, id: client.id, account_id: account.id)
      assert device.client_token_id == token.id
      assert device.public_key == attrs.public_key
      assert device.last_seen_at == timestamp
      assert_receive {:confirm_session_durability, ^conn_id}

      assert [session_log] = Repo.all(from(sl in SessionLog, where: sl.account_id == ^account.id))
      assert session_log.context == :client
      assert session_log.timestamp == timestamp
      assert session_log.subject["actor_id"] == actor.id
      assert session_log.subject["actor_email"] == actor.email
      assert session_log.subject["device_id"] == client.id
      assert session_log.subject["token_id"] == token.id
    end

    test "does not confirm durability when the session log write fails" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)
      conn_id = make_ref()

      :ok = PG.register(client.id)

      attrs = %{
        conn_id: conn_id,
        account_id: account.id,
        device_id: client.id,
        client_token_id: token.id,
        public_key: generate_public_key(),
        user_agent: "test-client/1.0",
        remote_ip: {100, 64, 0, 1},
        remote_ip_location_region: "US",
        version: "1.3.0",
        inserted_at: DateTime.utc_now()
      }

      on_flush = Keyword.fetch!(PortalAPI.Client.Socket.client_session_queue_opts(), :on_flush)

      # A NUL byte in the subject fails only the session_log insert (jsonb
      # rejects it), not the device upsert. The session lands but, because its
      # log did not, its durability is left unconfirmed so the timer can retry.
      metadata = %{subject: %{"actor_name" => "bad\0name"}, timestamp: DateTime.utc_now()}

      assert 1 = on_flush.([{attrs, metadata}])
      assert Repo.get_by!(Device, id: client.id, account_id: account.id).last_seen_at
      assert Repo.all(from(sl in SessionLog, where: sl.account_id == ^account.id)) == []
      refute_receive {:confirm_session_durability, ^conn_id}
    end

    test "disconnects entries whose token was deleted without confirming durability" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)
      conn_id = make_ref()

      :ok = PG.register(client.id)
      Repo.delete!(token)

      attrs = %{
        conn_id: conn_id,
        account_id: account.id,
        device_id: client.id,
        client_token_id: token.id,
        public_key: generate_public_key(),
        user_agent: "test-client/1.0",
        remote_ip: {100, 64, 0, 1},
        remote_ip_location_region: "US",
        version: "1.3.0",
        inserted_at: DateTime.utc_now()
      }

      on_flush = Keyword.fetch!(PortalAPI.Client.Socket.client_session_queue_opts(), :on_flush)

      metadata = %{subject: %{"actor_id" => actor.id}, timestamp: DateTime.utc_now()}

      assert 0 = on_flush.([{attrs, metadata}])

      device = Repo.get_by!(Device, id: client.id, account_id: account.id)
      assert is_nil(device.client_token_id)
      assert is_nil(device.last_seen_at)
      assert Repo.all(from(sl in SessionLog, where: sl.account_id == ^account.id)) == []
      assert_receive :disconnect
      refute_receive {:confirm_session_durability, ^conn_id}
    end
  end

  describe "gateway session queue callback" do
    test "inserts gateway sessions and confirms durability" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(account: account, site: site)
      conn_id = make_ref()

      :ok = PG.register(gateway.id)

      attrs = %{
        conn_id: conn_id,
        account_id: account.id,
        device_id: gateway.id,
        gateway_token_id: token.id,
        public_key: gateway.public_key,
        user_agent: "test-gateway/1.0",
        remote_ip: {100, 64, 0, 2},
        remote_ip_location_region: "US",
        version: "1.3.0",
        inserted_at: DateTime.utc_now()
      }

      on_flush = Keyword.fetch!(PortalAPI.Gateway.Socket.gateway_session_queue_opts(), :on_flush)

      timestamp = DateTime.utc_now()

      assert 1 = on_flush.([{attrs, %{timestamp: timestamp}}])

      device = Repo.get_by!(Device, id: gateway.id, account_id: account.id)
      assert device.gateway_token_id == token.id
      assert device.last_seen_at == timestamp
      assert_receive {:confirm_session_durability, ^conn_id}

      assert [session_log] = Repo.all(from(sl in SessionLog, where: sl.account_id == ^account.id))
      assert session_log.context == :gateway
      assert session_log.timestamp == timestamp
      assert session_log.subject["gateway_id"] == gateway.id
      assert session_log.subject["token_id"] == token.id
    end
  end

  describe "policy authorization queue callback" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      %{
        account: account,
        client: client,
        gateway: gateway,
        resource: resource,
        policy: policy,
        membership: membership,
        token: token
      }
    end

    test "inserts policy authorizations and confirms authz durability", ctx do
      authorization_id = Ecto.UUID.generate()
      :ok = PG.register(ctx.gateway.id)

      attrs = policy_authorization_attrs(ctx, %{id: authorization_id})
      on_flush = Keyword.fetch!(PortalAPI.Client.Channel.policy_authorization_queue_opts(), :on_flush)

      assert 1 = on_flush.([{attrs, nil}])
      assert Repo.get_by(PolicyAuthorization, id: authorization_id, account_id: ctx.account.id)
      assert_receive {:confirm_authz_durability, ^authorization_id}
    end

    test "rejects policy authorizations that fail FK partitioning", ctx do
      authorization_id = Ecto.UUID.generate()
      :ok = PG.register(ctx.gateway.id)

      attrs =
        policy_authorization_attrs(ctx, %{
          id: authorization_id,
          policy_id: Ecto.UUID.generate()
        })

      on_flush = Keyword.fetch!(PortalAPI.Client.Channel.policy_authorization_queue_opts(), :on_flush)

      assert 0 = on_flush.([{attrs, nil}])
      refute Repo.get_by(PolicyAuthorization, id: authorization_id, account_id: ctx.account.id)
      assert_receive {:reject_access, %PolicyAuthorization{id: ^authorization_id}}
    end
  end

  defp policy_authorization_attrs(ctx, overrides) do
    defaults = %{
      id: Ecto.UUID.generate(),
      account_id: ctx.account.id,
      token_id: ctx.token.id,
      policy_id: ctx.policy.id,
      initiating_device_id: ctx.client.id,
      receiving_device_id: ctx.gateway.id,
      resource_id: ctx.resource.id,
      membership_id: ctx.membership.id,
      initiator_remote_ip: {100, 64, 0, 1},
      initiator_user_agent: "test-client/1.0",
      receiver_remote_ip: %Postgrex.INET{address: {100, 64, 0, 2}},
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      inserted_at: DateTime.utc_now()
    }

    Map.merge(defaults, overrides)
  end
end
