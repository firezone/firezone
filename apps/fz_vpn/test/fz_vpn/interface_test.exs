defmodule FzVpn.InterfaceTest do
  use ExUnit.Case, async: true

  alias FzVpn.Interface
  alias FzVpn.Server

  test "delete interface" do
    name = "wg-delete"
    :ok = Interface.set(name, %{})

    assert :ok == Interface.delete(name)
  end

  test "list interface names" do
    expected_names = [Server.iface_name(), "wg0-list", "wg1-list"]
    Enum.each(expected_names, fn name -> Interface.set(name, %{}) end)
    {:ok, names} = Interface.list_names()
    Enum.each(expected_names, fn name -> :ok = Interface.delete(name) end)

    assert names == expected_names
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

    :ok = Interface.set(name, peers)
    :ok = Interface.remove_peer(name, public_key)
    {:ok, device} = Interface.get(name)
    :ok = Interface.delete(name)

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

      :ok = Interface.set(name, peers)
      interface_info = Interface.dump(name)
      :ok = Interface.delete(name)

      assert interface_info == @expected_interface_info
    end
  end
end
