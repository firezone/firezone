defmodule FzWall.CLI.SandboxTest do
  use ExUnit.Case, async: true

  import FzWall.CLI

  test "egress_address()" do
    assert is_binary(cli().egress_address())
  end
end
