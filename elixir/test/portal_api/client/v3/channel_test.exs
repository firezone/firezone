defmodule PortalAPI.Client.V3.ChannelTest do
  use PortalAPI.ChannelCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SubjectFixtures
  import Portal.TokenFixtures
  import Portal.TrustAnchorFixtures
  import Portal.FeaturesFixtures
  import Portal.DeviceTrustChallengeFixtures

  alias PortalAPI.Client.DeviceTrust

  setup do
    start_supervised!(
      {Portal.Queue,
       Keyword.merge(PortalAPI.Client.Channel.policy_authorization_queue_opts(),
         callers: [self()],
         flush_on_terminate: false
       )}
    )

    start_supervised!(
      {Portal.Queue,
       Keyword.merge(PortalAPI.Client.Socket.client_session_queue_opts(),
         callers: [self()],
         flush_on_terminate: false
       )}
    )

    account = account_fixture()
    enable_feature(:trust_anchors)
    trust_anchor_fixture(account: account, certs: [ca_der()])

    actor = actor_fixture(type: :account_admin_user, account: account)
    token = client_token_fixture(account: account, actor: actor)

    subject =
      subject_fixture(
        account: account,
        actor: actor,
        type: :client,
        token_id: token.id,
        user_agent: "Linux/24.04 connlib/1.3.0"
      )

    client = client_fixture(account: account, actor: actor, firezone_id: "fz-existing")

    %{account: account, actor: actor, subject: subject, client: client, token: token}
  end

  # Builds a socket in the deferred (pending_device) state, as V3.Socket.connect
  # leaves it on a gated account.
  defp deferred_socket(%{account: account, actor: actor, subject: subject, token: token}) do
    changeset =
      %Portal.Device{}
      |> Ecto.Changeset.cast(%{firezone_id: "fz-existing", name: "New Client"}, [
        :firezone_id,
        :name
      ])
      |> Ecto.Changeset.put_change(:type, :client)
      |> Ecto.Changeset.put_change(:account_id, account.id)
      |> Ecto.Changeset.put_change(:actor_id, actor.id)
      |> Portal.Device.changeset()

    pending = %{
      changeset: changeset,
      attrs: %{},
      token_id: token.id,
      public_key: generate_public_key(),
      version: "1.3.0",
      anchors: DeviceTrust.fetch_enabled_anchors(account.id)
    }

    PortalAPI.Client.V3.Socket
    |> socket("client:#{subject.credential.id}", %{
      subject: subject,
      pending_device: pending,
      session_ref: make_ref(),
      client_version: "1.3.0"
    })
  end

  defp join_v3(context) do
    context
    |> deferred_socket()
    |> subscribe_and_join(PortalAPI.Client.V3.Channel, "client")
  end

  describe "device trust challenge" do
    test "pushes a 32-byte nonce challenge before init", context do
      {:ok, _reply, _socket} = join_v3(context)

      assert_push "device_trust_request", %{nonce: nonce, subject_cn: "dev.firezone.device-trust"}
      refute_push "init", _payload, 100
      assert byte_size(Base.decode64!(nonce)) == 32
    end

    test "a valid response resolves the device, persists attested fields, and inits", context do
      {:ok, _reply, socket} = join_v3(context)
      assert_push "device_trust_request", %{nonce: nonce}

      entry = response_entry(:rsa, Base.decode64!(nonce))
      push(socket, "device_trust_response", [entry])

      assert_push "init", _payload, 2_000

      Portal.Queue.flush(:client_session_queue)

      device =
        Portal.Repo.get_by!(Portal.Device,
          id: context.client.id,
          account_id: context.account.id
        )

      assert device.last_attested_device_serial == "C02XK1ZGJGH5"
      assert device.last_attested_device_uuid == "7a461ff9-0be2-64a9-a418-539d9a21827b"
      assert device.last_attested_cert_fingerprint
      assert device.last_attested_at

      # The live session is marked attested in presence metadata.
      presence = Portal.Presence.Clients.Account.list(context.account.id)
      assert %{metas: [%{attested?: true}]} = Map.fetch!(presence, device.id)
    end

    test "a response with no usable certificate connects unverified", context do
      {:ok, _reply, socket} = join_v3(context)
      assert_push "device_trust_request", _payload

      push(socket, "device_trust_response", [])
      assert_push "init", _payload, 2_000

      Portal.Queue.flush(:client_session_queue)

      device =
        Portal.Repo.get_by!(Portal.Device,
          id: context.client.id,
          account_id: context.account.id
        )

      assert is_nil(device.last_attested_device_serial)
      assert is_nil(device.last_attested_cert_fingerprint)
      assert is_nil(device.last_attested_at)

      # The live session is explicitly unattested in presence metadata.
      presence = Portal.Presence.Clients.Account.list(context.account.id)
      assert %{metas: [%{attested?: false}]} = Map.fetch!(presence, device.id)
    end

    test "the challenge times out and connects unverified", context do
      Application.put_env(:portal, :device_trust_challenge_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:portal, :device_trust_challenge_timeout_ms) end)

      {:ok, _reply, _socket} = join_v3(context)
      assert_push "device_trust_request", _payload

      # No response sent; the timeout fires and init is pushed anyway.
      assert_push "init", _payload, 2_000
    end
  end

  describe "gate off" do
    test "without the feature the socket resolves at connect and does not challenge", context do
      disable_feature(:trust_anchors)

      assert DeviceTrust.fetch_enabled_anchors(context.account.id) == []
    end
  end
end
