defmodule FzCommon.FzStringTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzString

  describe "to_boolean/1" do
    test "converts to true" do
      assert true == FzString.to_boolean("True")
    end

    test "converts to false" do
      assert false == FzString.to_boolean("False")
    end

    test "raises exception on unknowns" do
      message = "Unknown boolean: string foobar not one of ['true', 'false']."

      assert_raise RuntimeError, message, fn ->
        FzString.to_boolean("foobar")
      end
    end
  end
end
