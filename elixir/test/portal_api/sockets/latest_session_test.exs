defmodule PortalAPI.Sockets.LatestSessionTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.TokenFixtures

  alias PortalAPI.Sockets.LatestSession

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account)
    token = client_token_fixture(account: account)

    client =
      client_fixture(account: account, actor: actor, firezone_id: "client-supplied")

    %{account: account, client: client, token: token}
  end

  describe "upsert_all/2" do
    test "clears the firezone_id of a device identified only by its certificate", %{
      client: client,
      token: token
    } do
      # A certificate asserting no MDM device id still attests, resolved by its
      # pinned fingerprint. Leaving the client-supplied id on the row would let
      # a later unattested connect adopt it.
      upsert(attested_entry(client, token, mdm_device_id: nil))

      device = Repo.get_by!(Portal.Device, account_id: client.account_id, id: client.id)
      assert is_nil(device.firezone_id)
    end

    test "persists the issuer of the certificate that was presented", %{
      client: client,
      token: token
    } do
      # Written through the flush rather than the changeset for a row that
      # already existed, so an issuer missing here never reaches the column and
      # revocation cannot match the device by issuer and serial.
      upsert(attested_entry(client, token))

      device = Repo.get_by!(Portal.Device, account_id: client.account_id, id: client.id)
      assert device.last_attested_cert_issuer == <<"issuer-der">>
      assert device.last_attested_cert_serial == "AABBCC"
    end

    test "leaves the firezone_id of an unattested device alone", %{client: client, token: token} do
      upsert(client |> attested_entry(token) |> Map.drop(attested_keys()))

      device = Repo.get_by!(Portal.Device, account_id: client.account_id, id: client.id)
      assert device.firezone_id == "client-supplied"
    end

    test "persists a tokenless X.509 session without treating it as revoked", %{
      client: client,
      token: token
    } do
      entry = client |> attested_entry(token) |> Map.put(:token_id, nil)

      assert {1, [], []} = upsert(entry)

      device = Repo.get_by!(Portal.Device, account_id: client.account_id, id: client.id)
      assert is_nil(device.token_id)
      assert is_nil(device.token_id)
    end
  end

  describe "device actors" do
    test "records the actor that connected on the device", %{client: client, token: token} do
      connected_at = DateTime.utc_now()

      assert {1, [], []} = upsert(entry(client, token), connected_at)

      row = device_actor(client, client.actor_id)
      assert DateTime.compare(row.first_seen_at, connected_at) == :eq
      assert DateTime.compare(row.last_seen_at, connected_at) == :eq
    end

    test "a later connect moves last seen and keeps first seen", %{client: client, token: token} do
      first = DateTime.utc_now() |> DateTime.add(-1, :day)
      later = DateTime.utc_now()

      upsert(entry(client, token), first)
      upsert(entry(client, token), later)

      row = device_actor(client, client.actor_id)
      assert DateTime.compare(row.first_seen_at, first) == :eq
      assert DateTime.compare(row.last_seen_at, later) == :eq
    end

    test "a flush of an older session never narrows the window", %{client: client, token: token} do
      earlier = DateTime.utc_now() |> DateTime.add(-1, :day)
      later = DateTime.utc_now()

      upsert(entry(client, token), later)
      upsert(entry(client, token), earlier)

      row = device_actor(client, client.actor_id)
      assert DateTime.compare(row.first_seen_at, earlier) == :eq
      assert DateTime.compare(row.last_seen_at, later) == :eq
    end

    test "another actor on the same device gets its own row", %{
      account: account,
      client: client,
      token: token
    } do
      other = actor_fixture(account: account)

      upsert(entry(client, token))
      upsert(%{entry(client, token) | actor_id: other.id})

      assert device_actor(client, client.actor_id)
      assert device_actor(client, other.id)
    end

    test "several connects of one pair in a batch collapse into one row", %{
      client: client,
      token: token
    } do
      first = DateTime.utc_now() |> DateTime.add(-1, :hour)
      later = DateTime.utc_now()

      assert {2, [], []} =
               LatestSession.upsert_all([
                 {entry(client, token), %{timestamp: later}},
                 {entry(client, token), %{timestamp: first}}
               ])

      row = device_actor(client, client.actor_id)
      assert DateTime.compare(row.first_seen_at, first) == :eq
      assert DateTime.compare(row.last_seen_at, later) == :eq
    end

    test "an entry without an actor records nothing", %{client: client, token: token} do
      assert {1, [], []} = upsert(%{entry(client, token) | actor_id: nil})

      assert Repo.aggregate(Portal.DeviceActor, :count) == 0
    end

    test "an actor deleted before the flush is skipped without failing the batch", %{
      account: account,
      client: client,
      token: token
    } do
      # The device owner's deletion takes the device with it; a second actor
      # on the same machine is the one that can vanish on its own.
      other = actor_fixture(account: account)
      Repo.delete!(other)

      assert {1, [], []} = upsert(%{entry(client, token) | actor_id: other.id})

      refute device_actor(client, other.id)
    end

    test "a device deleted before the flush is reported without failing the batch", %{
      account: account,
      token: token
    } do
      client = client_fixture(account: account)
      Repo.delete!(client)

      assert {0, [], [_missing]} = upsert(entry(client, token))

      assert Repo.aggregate(Portal.DeviceActor, :count) == 0
    end
  end

  defp upsert(attrs, timestamp \\ DateTime.utc_now()) do
    LatestSession.upsert_all([{attrs, %{timestamp: timestamp}}])
  end

  defp device_actor(client, actor_id) do
    Repo.get_by(Portal.DeviceActor,
      account_id: client.account_id,
      device_id: client.id,
      actor_id: actor_id
    )
  end

  defp entry(client, token) do
    client |> attested_entry(token) |> Map.drop(attested_keys())
  end

  defp attested_keys do
    ~w[last_attested_device_serial last_attested_device_uuid last_attested_mdm_device_id
       last_attested_cert_serial last_attested_cert_fingerprint last_attested_cert_issuer
       last_attested_at]a
  end

  defp attested_entry(client, token, opts \\ []) do
    %{
      session_ref: make_ref(),
      account_id: client.account_id,
      device_id: client.id,
      actor_id: client.actor_id,
      firezone_id: nil,
      last_attested_mdm_device_id: Keyword.get(opts, :mdm_device_id, "mdm-1"),
      last_attested_cert_serial: "AABBCC",
      last_attested_cert_fingerprint: "fp-1",
      last_attested_cert_issuer: <<"issuer-der">>,
      last_attested_at: DateTime.utc_now(),
      token_id: token.id,
      public_key: generate_public_key(),
      user_agent: "iOS/12.5 (iPhone) connlib/1.4.0",
      remote_ip: %Postgrex.INET{address: {100, 64, 0, 2}},
      version: "1.4.0"
    }
  end
end
