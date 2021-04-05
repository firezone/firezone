defmodule FgCommon.NameGeneratorTest do
  use ExUnit.Case, async: true

  alias FgCommon.NameGenerator

  describe "generate/0" do
    test "generates a name" do
      assert is_binary(NameGenerator.generate())
    end

    test "successive runs generate different names" do
      name1 = NameGenerator.generate()
      name2 = NameGenerator.generate()
      assert name1 != name2
    end
  end
end
