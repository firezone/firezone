defmodule FgVpn.ConfigTest do
  use ExUnit.Case, async: true
  alias FgVpn.Config

  @empty """
  """

  @single_peer """
  # BEGIN PEER test-pubkey
  [Peer]
  PublicKey = test-pubkey
  AllowedIPs = 0.0.0.0/0, ::/0
  # END PEER test-pubkey
  """

  def write_config(config) do
    Application.get_env(:fg_vpn, :wireguard_conf_path)
    |> File.write!(config)
  end

  setup %{stubbed_config: config} do
    write_config(config)
    test_pid = start_supervised!(Config)

    on_exit(fn ->
      Application.get_env(:fg_vpn, :wireguard_conf_path)
      |> File.rm!()
    end)

    %{test_pid: test_pid}
  end

  @tag stubbed_config: @single_peer
  test "parses peers from config file", %{test_pid: test_pid} do
    state = :sys.get_state(test_pid)
    assert state == ["test-pubkey"]
  end

  @tag stubbed_config: @empty
  test "writes peers to config when device is verified", %{test_pid: test_pid} do
    send(test_pid, {:verify_device, "test-pubkey"})

    # XXX: Avoid sleeping
    Process.sleep(100)

    assert Config.read() == ["test-pubkey"]
  end

  @tag stubbed_config: @single_peer
  test "removes peers from config when device is removed", %{test_pid: test_pid} do
    send(test_pid, {:remove_device, "test-pubkey"})

    # XXX: Avoid sleeping
    Process.sleep(100)

    assert Config.read() == []
  end
end
