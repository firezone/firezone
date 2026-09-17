defmodule PortalWeb.Policies.Postures.JSONSpanTest do
  use ExUnit.Case, async: true

  alias PortalWeb.Policies.Postures.JSONSpan

  @text ~s({
  "and": [
    {"field": "intune.jail_broken", "op": "is", "value": false},
    {"not": {"or": [{"field": "firezone.hostname", "op": "is_in", "value": ["a", "b,]"]}]}}
  ]
})

  defp slice(path) do
    case JSONSpan.locate(@text, path) do
      nil -> nil
      {start, length} -> binary_part(@text, start, length)
    end
  end

  test "finds scalars, strings and lists by key and index" do
    assert slice(["and", 0, "value"]) == "false"
    assert slice(["and", 0, "field"]) == ~s("intune.jail_broken")
    assert slice(["and", 1, "not", "or", 0, "value"]) == ~s(["a", "b,]"])
    assert slice(["and", 1, "not", "or", 0, "op"]) == ~s("is_in")
  end

  test "finds whole objects and arrays" do
    assert slice(["and", 1, "not"]) =~ ~r/^\{"or": \[.*\]\}$/
    assert slice(["and"]) =~ ~r/^\[\n.*\n  \]$/s
    assert slice([]) == @text
  end

  test "returns nil for a missing key or index" do
    assert slice(["and", 0, "rows"]) == nil
    assert slice(["and", 5]) == nil
    assert slice(["or"]) == nil
  end

  test "skips escaped quotes inside strings" do
    text = ~s({"field": "a\\"b", "op": "is", "value": 1})
    assert JSONSpan.locate(text, ["value"]) == {byte_size(text) - 2, 1}
  end

  test "gives up quietly on truncated text" do
    assert JSONSpan.locate(~s({"and": [{"field": ), ["and", 0, "field"]) == nil
    assert JSONSpan.locate("", []) == nil
  end
end
