defmodule FgVpn.CLI.SandboxTest do
  use ExUnit.Case, async: true

  import FgVpn.CLI

  @expected_returned ""

  test "egress_interface" do
    assert is_binary(cli().egress_interface())
  end

  test "setup" do
    assert cli().setup() == @expected_returned
  end

  test "teardown" do
    assert cli().teardown() == @expected_returned
  end

  test "genkey" do
    {privkey, pubkey} = cli().genkey()

    assert is_binary(privkey)
    assert is_binary(pubkey)
  end

  test "pubkey" do
    {privkey, _pubkey} = cli().genkey()
    pubkey = cli().pubkey(privkey)

    assert is_binary(pubkey)
    assert String.length(pubkey) == 44
  end

  test "exec!" do
    assert cli().exec!("dummy") == @expected_returned
  end

  test "set" do
    assert cli().set("dummy") == @expected_returned
  end

  test "show_latest_handshakes" do
    assert cli().show_latest_handshakes() == "4 seconds ago"
  end

  test "show_persistent_keepalives" do
    assert cli().show_persistent_keepalives() == "every 25 seconds"
  end

  test "show_transfer" do
    assert cli().show_transfer() == "4.60 MiB received, 59.21 MiB sent"
  end
end
