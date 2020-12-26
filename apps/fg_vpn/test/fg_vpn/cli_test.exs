defmodule FgVpn.CLITest do
  use ExUnit.Case, async: true

  alias FgVpn.CLI

  test "default_interface" do
    assert is_binary(CLI.default_interface())
  end

  test "genkey" do
    {privkey, pubkey} = CLI.genkey()

    assert is_binary(privkey)
    assert is_binary(pubkey)
  end
end
