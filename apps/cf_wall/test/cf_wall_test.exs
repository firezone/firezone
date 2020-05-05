defmodule CfWallTest do
  use ExUnit.Case
  doctest CfWall

  test "greets the world" do
    assert CfWall.hello() == :world
  end
end
