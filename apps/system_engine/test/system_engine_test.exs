defmodule FirewallDaemonTest do
  use ExUnit.Case
  doctest FirewallDaemon

  test "greets the world" do
    assert FirewallDaemon.hello() == :world
  end
end
