defmodule Portal.DevicesTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures

  alias Portal.Device
  alias Portal.Devices
  alias Portal.GatewayToken

  describe "provision_gateway/3" do
    test "creates a gateway and mints its single-owner token" do
      account = account_fixture()
      site = site_fixture(account: account)
      subject =
        subject_fixture(account: account, actor: %{type: :api_client, account: account})

      assert {:ok, %Device{} = gateway, %GatewayToken{} = token, encoded_token} =
               Devices.provision_gateway(site, "edge-nyc-1", subject)

      assert gateway.name == "edge-nyc-1"
      assert gateway.site_id == site.id
      assert gateway.account_id == site.account_id
      assert gateway.type == :gateway

      assert token.device_id == gateway.id
      assert is_nil(token.site_id)
      # secret_fragment is scrubbed - only the encoded token carries the secret.
      assert is_nil(token.secret_fragment)
      assert is_binary(encoded_token)
    end

    test "generates a random name when none is given" do
      account = account_fixture()
      site = site_fixture(account: account)
      subject =
        subject_fixture(account: account, actor: %{type: :api_client, account: account})

      assert {:ok, %Device{name: name}, _token, _encoded_token} =
               Devices.provision_gateway(site, nil, subject)

      refute is_nil(name)
      refute name == ""
    end
  end
end
