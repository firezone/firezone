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
  end

  defp upsert(attrs) do
    LatestSession.upsert_all([{attrs, %{timestamp: DateTime.utc_now()}}], :client_token_id)
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
      client_token_id: token.id,
      public_key: generate_public_key(),
      user_agent: "iOS/12.5 (iPhone) connlib/1.4.0",
      remote_ip: %Postgrex.INET{address: {100, 64, 0, 2}},
      version: "1.4.0"
    }
  end
end
