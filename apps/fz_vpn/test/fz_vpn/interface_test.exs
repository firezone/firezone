defmodule FzVpn.InterfaceTest do
  use ExUnit.Case, async: true

  alias FzVpn.Interface

  test "create interface" do
    name = "wg-create"
    {:ok, key_pair} = Interface.create(name, nil, nil, nil, nil)
    {private_key, public_key} = key_pair
    {:ok, device} = Interface.get(name)

    assert device.name == name && device.private_key == private_key &&
             device.public_key == public_key
  end

  test "delete interface" do
    name = "wg-delete"
    :ok = Interface.set(name, nil, [])
    :ok = Interface.delete(name)
    {:ok, device} = Interface.get(name)

    assert is_nil(device)
  end

  test "remove peer from interface" do
    name = "wg-remove-peer"
    public_key = "+wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0="

    peers = %{
      public_key => %{
        allowed_ips: "10.3.2.7/32,fd00::3:2:7/128",
        preshared_key: nil
      }
    }

    :ok = Interface.set(name, nil, peers)
    :ok = Interface.remove_peer(name, public_key)
    {:ok, device} = Interface.get(name)

    assert device.peers == []
  end

  describe "getting interface peer stats" do
    @expected_interface_info %{
      "+wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0=" => %{
        allowed_ips: "10.3.2.7/32,fd00::3:2:7/128",
        endpoint: "(none)",
        latest_handshake: "0",
        persistent_keepalive: "off",
        preshared_key: "(none)",
        rx_bytes: "0",
        tx_bytes: "0"
      },
      "JOvewkquusVzBHIRjvq32gE4rtsmDKyGh8ubhT4miAY=" => %{
        allowed_ips: "10.3.2.8/32,fd00::3:2:8/128",
        endpoint: "(none)",
        latest_handshake: "0",
        persistent_keepalive: "off",
        preshared_key: "(none)",
        rx_bytes: "0",
        tx_bytes: "0"
      }
    }

    test "dump interface info" do
      name = "wg-dump"

      peers = %{
        "+wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0=" => %{
          allowed_ips: "10.3.2.7/32,fd00::3:2:7/128",
          preshared_key: nil
        },
        "JOvewkquusVzBHIRjvq32gE4rtsmDKyGh8ubhT4miAY=" => %{
          allowed_ips: "10.3.2.8/32,fd00::3:2:8/128",
          preshared_key: nil
        }
      }

      :ok = Interface.set(name, nil, peers)
      interface_info = Interface.dump(name)

      assert interface_info == @expected_interface_info
    end
  end
end
