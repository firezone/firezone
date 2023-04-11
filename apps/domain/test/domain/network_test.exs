defmodule Domain.NetworkTest do
  use Domain.DataCase, async: true
  import Domain.Network

  # TODO: this should claim next address instead of just returning it?
  describe "fetch_next_available_address/1" do
    # test "soft limit max network range for IPv6", %{admin_user: user, admin_subject: subject} do
    #   attrs =
    #     ClientsFixtures.client_attrs()
    #     |> Map.take([:public_key])

    #   {:ok, cidr} = Domain.Types.CIDR.cast("fd00::/20")
    #   Domain.Config.put_env_override(:wireguard_ipv6_network, cidr)
    #   assert {:ok, client} = upsert_client(attrs, subject)
    #   assert %Postgrex.INET{address: {64_768, 0, 0, 0, _, _, _, _}, netmask: nil} = client.ipv6
    # end
  end
end
