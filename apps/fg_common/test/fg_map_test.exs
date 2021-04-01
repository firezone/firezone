defmodule FgCommon.FgMapTest do
  use ExUnit.Case, async: true

  alias FgCommon.FgMap

  describe "compact/1" do
    @data %{foo: nil, bar: "hello"}

    test "removes nil values" do
      assert FgMap.compact(@data) == %{bar: "hello"}
    end
  end

  describe "compact/2" do
    @data %{foo: "bar", bar: ""}

    test "removes matched values" do
      assert FgMap.compact(@data, "") == %{foo: "bar"}
    end
  end
end
