defmodule FgCommon.FgMapTest do
  use ExUnit.Case, async: true

  alias FgCommon.FgMap

  describe "compact" do
    test "it compacts the map" do
      data = %{foo: nil, bar: "hello"}

      assert FgMap.compact(data) == %{bar: "hello"}
    end
  end
end
