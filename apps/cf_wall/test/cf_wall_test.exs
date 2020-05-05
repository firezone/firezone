defmodule SystemEngineTest do
  use ExUnit.Case
  doctest SystemEngine

  test "greets the world" do
    assert SystemEngine.hello() == :world
  end
end
