defmodule FzVpn.CLI.SandboxTest do
  use ExUnit.Case, async: true

  import FzVpn.CLI

  @expected_returned ""

  test "setup" do
    assert cli().setup() == @expected_returned
  end

  test "teardown" do
    assert cli().teardown() == @expected_returned
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

  test "show_persistent_keepalive" do
    assert cli().show_persistent_keepalive() == "every 25 seconds"
  end

  test "show_transfer" do
    assert cli().show_transfer() == "4.60 MiB received, 59.21 MiB sent"
  end

  test "show_dump" do
    assert cli().show_dump() ==
             """
             0A+FvaRbBjKan9hyjolIpjpwaz9rguSeNCXNtoOiLmg=	7E8wSJ2ue1l2cRm/NsqkFfmb0HZxc+3Dg373BVcMxx4=	51820	off
             +wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0=	(none)	140.82.48.115:54248	10.3.2.7/32,fd00::3:2:7/128	1650286790	14161600	3668160	off
             JOvewkquusVzBHIRjvq32gE4rtsmDKyGh8ubhT4miAY=	(none)	149.28.197.67:44491	10.3.2.8/32,fd00::3:2:8/128	1650286747	177417128	138272552	off
             """
  end
end
