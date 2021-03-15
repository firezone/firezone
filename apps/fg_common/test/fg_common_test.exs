defmodule FgCommonTest do
  use ExUnit.Case
  doctest FgCommon

  test "greets the world" do
    assert FgCommon.hello() == :world
  end
end
