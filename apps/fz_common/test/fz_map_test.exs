defmodule FzCommon.FzMapTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzMap

  describe "compact/1" do
    @data %{foo: nil, bar: "hello"}

    test "removes nil values" do
      assert FzMap.compact(@data) == %{bar: "hello"}
    end
  end

  describe "compact/2" do
    @data %{foo: "bar", bar: ""}

    test "removes matched values" do
      assert FzMap.compact(@data, "") == %{foo: "bar"}
    end
  end

  describe "stringify_keys/1" do
    @data %{foo: "bar", bar: "", map: %{foo: "bar"}}

    test "stringifies the keys" do
      assert FzMap.stringify_keys(@data) == %{
               "foo" => "bar",
               "bar" => "",
               "map" => %{
                 foo: "bar"
               }
             }
    end
  end

  describe "map_to_keyword_list/1" do
    @data %{"foo" => "bar", "bar" => "", "map" => %{"foo" => "bar"}}
    @expected [foo: "bar", bar: "", map: [foo: "bar"]]

    test "converts a map to a keyword list" do
      result = FzMap.map_to_keyword_list(@data)

      assert Enum.sort(result) == Enum.sort(@expected),
             "Result #{inspect(result)}, Expected: #{inspect(@expected)}"
    end
  end
end
