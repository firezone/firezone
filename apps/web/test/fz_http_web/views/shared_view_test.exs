defmodule FzHttpWeb.SharedViewTest do
  use ExUnit.Case, async: true
  import FzHttpWeb.SharedView

  describe "to_human_bytes/1" do
    test "handles expected cases" do
      for {bytes, str} <- [
            {nil, "0.00 B"},
            {1_023, "1023.00 B"},
            {1_023_999_999_999_999_999_999, "888.18 EiB"},
            {1_000, "1000.00 B"},
            {1_115, "1.09 KiB"},
            {987_654_321_123_456_789_987, "856.65 EiB"}
          ] do
        assert to_human_bytes(bytes) == str
      end
    end
  end
end
