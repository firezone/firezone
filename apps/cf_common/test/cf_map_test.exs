defmodule CfCommon.CfMapTest do
  use ExUnit.Case, async: true

  alias CfCommon.CfMap

  describe "compact/1" do
    @data %{foo: nil, bar: "hello"}

    test "removes nil values" do
      assert CfMap.compact(@data) == %{bar: "hello"}
    end
  end

  describe "compact/2" do
    @data %{foo: "bar", bar: ""}

    test "removes matched values" do
      assert CfMap.compact(@data, "") == %{foo: "bar"}
    end
  end
end
