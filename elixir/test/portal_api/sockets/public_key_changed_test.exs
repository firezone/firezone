defmodule PortalAPI.Sockets.PublicKeyChangedTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  alias PortalAPI.Sockets

  test "tells each peer of a device without a type the role it has toward that peer" do
    account = account_fixture()
    device = typeless_device_fixture(account: account)
    site = site_fixture(account: account)
    site_resource = resource_fixture(account: account, site: site)
    pool = device_pool_resource_fixture(account: account, devices: [device])

    site_initiator = client_fixture(account: account)
    pool_initiator = client_fixture(account: account)
    receiver = gateway_fixture(account: account, site: site)

    policy_authorization_fixture(account: account, client: site_initiator, gateway: device, resource: site_resource)
    policy_authorization_fixture(account: account, client: pool_initiator, gateway: device, resource: pool)
    policy_authorization_fixture(account: account, client: device, gateway: receiver, resource: site_resource)

    for peer <- [site_initiator, pool_initiator, receiver], do: :ok = Portal.PG.join(peer.id)

    device = %{device | public_key: generate_public_key()}
    :ok = Sockets.notify_public_key_changed(device, generate_public_key())

    device_id = device.id
    public_key = device.public_key
    assert_receive {:public_key_changed, :gateway, ^device_id, ^public_key}
    assert_receive {:public_key_changed, :client, ^device_id, ^public_key}
    assert_receive {:public_key_changed, :client, ^device_id, ^public_key}
    refute_received {:public_key_changed, _, _, _}
  end
end
