defmodule FgWallTest do
  use ExUnit.Case
  doctest FgWall

  test "greets the world" do
    assert FgWall.hello() == :world
  end
end
