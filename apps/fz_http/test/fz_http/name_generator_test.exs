defmodule FzHttp.NameGeneratorTest do
  use ExUnit.Case, async: true
  import FzHttp.NameGenerator

  describe "generate/0" do
    test "generates a name" do
      assert is_binary(generate())
    end

    test "successive runs generate different names" do
      name1 = generate()
      name2 = generate()
      assert name1 != name2
    end
  end
end
