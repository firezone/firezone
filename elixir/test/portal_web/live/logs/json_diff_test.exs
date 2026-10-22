defmodule PortalWeb.Logs.JSONDiffTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PortalWeb.Logs.JSONDiff

  # ---------- changed_field_count ----------

  describe "changed_field_count/2" do
    test "counts only top-level keys that differ" do
      assert JSONDiff.changed_field_count(%{"a" => 1, "b" => 2}, %{"a" => 1, "b" => 3}) == 1
      assert JSONDiff.changed_field_count(%{"a" => 1, "b" => 2}, %{"a" => 9, "b" => 9}) == 2
    end

    test "added and removed keys count as differences" do
      assert JSONDiff.changed_field_count(%{"a" => 1}, %{"a" => 1, "b" => 2}) == 1
      assert JSONDiff.changed_field_count(%{"a" => 1, "b" => 2}, %{"a" => 1}) == 1
    end

    test "treats nil sides as full inserts or deletes" do
      assert JSONDiff.changed_field_count(nil, %{"a" => 1, "b" => 2}) == 2
      assert JSONDiff.changed_field_count(%{"a" => 1, "b" => 2}, nil) == 2
      assert JSONDiff.changed_field_count(nil, nil) == 0
    end
  end

  # ---------- compute_diff ----------

  describe "compute_diff/2" do
    test "deep-equal values produce no delta" do
      assert JSONDiff.compute_diff(nil, nil) == nil
      assert JSONDiff.compute_diff(1, 1) == nil
      assert JSONDiff.compute_diff("x", "x") == nil
      assert JSONDiff.compute_diff(%{"a" => 1}, %{"a" => 1}) == nil
      assert JSONDiff.compute_diff([1, [2, 3]], [1, [2, 3]]) == nil
    end

    test "nil on one side collapses to add or delete" do
      assert JSONDiff.compute_diff(nil, %{"a" => 1}) == {:add, %{"a" => 1}}
      assert JSONDiff.compute_diff(%{"a" => 1}, nil) == {:del, %{"a" => 1}}
      assert JSONDiff.compute_diff(nil, 5) == {:add, 5}
      assert JSONDiff.compute_diff("foo", nil) == {:del, "foo"}
    end

    test "primitive change becomes :mod" do
      assert JSONDiff.compute_diff(1, 2) == {:mod, 1, 2}
      assert JSONDiff.compute_diff(false, true) == {:mod, false, true}
      assert JSONDiff.compute_diff("a", "b") == {:mod, "a", "b"}
    end

    test "type mismatch becomes :mod" do
      assert JSONDiff.compute_diff("1", 1) == {:mod, "1", 1}
      assert JSONDiff.compute_diff([], %{}) == {:mod, [], %{}}
    end

    test "object diff carries added / deleted / changed children" do
      delta = JSONDiff.compute_diff(%{"a" => 1, "b" => 2, "c" => 3}, %{"a" => 1, "b" => 9, "d" => 4})

      {:node, %{kind: :object, children: children}} = delta
      by_key = Map.new(children, &{&1.key, &1})

      assert by_key["a"].state == :unchanged
      assert by_key["b"].state == :changed
      assert by_key["b"].delta == {:mod, 2, 9}
      assert by_key["c"].state == :deleted
      assert by_key["d"].state == :added
    end

    test "object keys are alphabetically sorted in output" do
      {:node, %{children: children}} =
        JSONDiff.compute_diff(%{"z" => 1, "a" => 2}, %{"z" => 9, "a" => 8})

      assert Enum.map(children, & &1.key) == ["a", "z"]
    end

    test "nil to value at a shared key becomes :added (not :changed + :add)" do
      # Regression: child_for_paired_keys must not produce a `:changed`
      # state wrapping an `{:add, _}` delta — `render_child/1` has no
      # clause for that combination and would crash the LV at render.
      {:node, %{children: children}} =
        JSONDiff.compute_diff(%{"ip_stack" => nil}, %{"ip_stack" => "dual"})

      assert [%{key: "ip_stack", state: :added, right_value: "dual"}] = children
    end

    test "value to nil at a shared key becomes :deleted (not :changed + :del)" do
      {:node, %{children: children}} =
        JSONDiff.compute_diff(%{"slug" => "old"}, %{"slug" => nil})

      assert [%{key: "slug", state: :deleted, left_value: "old"}] = children
    end

    test "booleans, numbers, and floats produce a :mod" do
      assert JSONDiff.compute_diff(true, false) == {:mod, true, false}
      assert JSONDiff.compute_diff(0, 1) == {:mod, 0, 1}
      assert JSONDiff.compute_diff(1.5, 2.5) == {:mod, 1.5, 2.5}
    end

    test "integer-vs-float comparison treats unequal values as :mod" do
      # Elixir's `==` between 1 and 1.0 is true; the diff should agree.
      assert JSONDiff.compute_diff(1, 1.0) == nil
      assert JSONDiff.compute_diff(1, 1.5) == {:mod, 1, 1.5}
    end

    test "every primitive cross-type pair is treated as a :mod" do
      pairs = [
        {"x", 1},
        {1, true},
        {true, "true"},
        {nil, false},
        {false, nil},
        {[1], %{"a" => 1}},
        {%{}, []}
      ]

      for {left, right} <- pairs do
        delta = JSONDiff.compute_diff(left, right)

        assert match?({:mod, _, _}, delta) or match?({:add, _}, delta) or
                 match?({:del, _}, delta),
               "expected a leaf-shaped delta for #{inspect(left)} vs #{inspect(right)}, got: #{inspect(delta)}"
      end
    end

    test "deep-equal values across many shapes all return nil" do
      shapes = [
        nil,
        true,
        false,
        0,
        1.5,
        "",
        "x",
        [],
        %{},
        [1, 2, 3],
        %{"a" => 1, "b" => [%{"c" => true}]},
        ["x", %{"y" => [1, 2]}]
      ]

      for value <- shapes do
        # Use a deep-copy via JSON round-trip so we're comparing distinct
        # references with equal content.
        clone = value |> JSON.encode!() |> JSON.decode!()
        assert JSONDiff.compute_diff(value, clone) == nil
      end
    end
  end

  # ---------- arrays ----------

  describe "compute_diff/2 with arrays" do
    test "removing a middle element only deletes that element" do
      {:node, %{kind: :array, children: children}} =
        JSONDiff.compute_diff(["a", "b", "c"], ["a", "c"])

      assert Enum.map(children, & &1.state) == [:unchanged, :deleted, :unchanged]
    end

    test "appending an element only adds it" do
      {:node, %{kind: :array, children: children}} =
        JSONDiff.compute_diff([1, 2, 3], [1, 2, 3, 4])

      assert Enum.map(children, & &1.state) == [:unchanged, :unchanged, :unchanged, :added]
    end

    test "changing the last element marks it as changed not replaced" do
      {:node, %{kind: :array, children: children}} =
        JSONDiff.compute_diff([1, 2, 3], [1, 2, 4])

      states = Enum.map(children, & &1.state)
      assert states == [:unchanged, :unchanged, :changed]
    end

    test "objects without identity fields pair positionally so similar items show as changes" do
      # Mirrors the production traffic-filters case: two filters at the
      # same index, one of them mutates ports.
      left = [
        %{"protocol" => "tcp", "ports" => ["80"]},
        %{"protocol" => "udp", "ports" => ["53"]}
      ]

      right = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]

      {:node, %{kind: :array, children: children}} = JSONDiff.compute_diff(left, right)

      states = Enum.map(children, & &1.state)
      assert :changed in states, "tcp item should be a structural diff, not delete+add"
      assert :deleted in states, "udp item should be deleted"
    end

    test "objects with id fields pair across positions" do
      left = [%{"id" => "x", "name" => "old"}]
      right = [%{"id" => "x", "name" => "new"}]

      {:node, %{kind: :array, children: [child]}} = JSONDiff.compute_diff(left, right)

      assert child.state == :changed
      {:node, %{kind: :object, children: inner}} = child.delta
      name_child = Enum.find(inner, &(&1.key == "name"))
      assert name_child.delta == {:mod, "old", "new"}
    end

    test "empty to populated array surfaces every element as added" do
      {:node, %{kind: :array, children: children}} = JSONDiff.compute_diff([], [1, 2, 3])
      assert Enum.map(children, & &1.state) == [:added, :added, :added]
      assert Enum.map(children, & &1.right_value) == [1, 2, 3]
    end

    test "populated to empty array surfaces every element as deleted" do
      {:node, %{kind: :array, children: children}} = JSONDiff.compute_diff([1, 2, 3], [])
      assert Enum.map(children, & &1.state) == [:deleted, :deleted, :deleted]
      assert Enum.map(children, & &1.left_value) == [1, 2, 3]
    end

    test "deletion at the start vs end is reflected positionally" do
      # Remove the head: only [0] is deleted.
      {:node, %{children: head}} = JSONDiff.compute_diff([1, 2, 3], [2, 3])
      assert Enum.map(head, & &1.state) == [:deleted, :unchanged, :unchanged]

      # Remove the tail: only the last is deleted.
      {:node, %{children: tail}} = JSONDiff.compute_diff([1, 2, 3], [1, 2])
      assert Enum.map(tail, & &1.state) == [:unchanged, :unchanged, :deleted]
    end

    test "two element swap shows the moved item without an explicit move op" do
      # We don't track moves, so a swap surfaces as some combination of
      # an LCS match for one side and an add/del for the other. The
      # important property is that we never crash and the number of
      # children equals max(left, right) + adjustment for the swap.
      {:node, %{children: children}} = JSONDiff.compute_diff(["a", "b"], ["b", "a"])
      states = Enum.map(children, & &1.state)
      assert Enum.all?(states, &(&1 in [:unchanged, :added, :deleted, :changed]))
      # At minimum some movement must be reported.
      refute Enum.all?(states, &(&1 == :unchanged))
    end

    test "nested arrays inside arrays diff recursively" do
      {:node, %{children: [child]}} =
        JSONDiff.compute_diff([[1, 2, 3]], [[1, 2, 4]])

      assert child.state == :changed
      {:node, %{kind: :array, children: inner}} = child.delta
      assert Enum.map(inner, & &1.state) == [:unchanged, :unchanged, :changed]
    end

    test "array of mixed primitive types diffs element by element" do
      {:node, %{children: children}} =
        JSONDiff.compute_diff([1, "a", true, nil], [1, "b", true, nil])

      assert Enum.map(children, & &1.state) == [:unchanged, :changed, :unchanged, :unchanged]
      changed = Enum.at(children, 1)
      assert changed.delta == {:mod, "a", "b"}
    end
  end

  # ---------- strings ----------

  describe "compute_diff/2 with strings" do
    test "short strings produce a plain mod" do
      assert JSONDiff.compute_diff("hi", "bye") == {:mod, "hi", "bye"}
    end

    test "long strings produce a word-level textmod" do
      # Both > 60 bytes so the textmod path triggers.
      left = String.duplicate("a", 30) <> " brown " <> String.duplicate("z", 30)
      right = String.duplicate("a", 30) <> " red " <> String.duplicate("z", 30)

      {:textmod, segments} = JSONDiff.compute_diff(left, right)

      ops = Enum.map(segments, & &1.op)
      assert :eq in ops
      assert :add in ops
      assert :del in ops

      del_text = segments |> Enum.filter(&(&1.op == :del)) |> Enum.map_join("", & &1.text)
      add_text = segments |> Enum.filter(&(&1.op == :add)) |> Enum.map_join("", & &1.text)
      assert del_text =~ "brown"
      assert add_text =~ "red"
    end

    test "consecutive same-op tokens are coalesced into one segment" do
      left = String.duplicate("x ", 40) <> "alpha beta gamma"
      right = String.duplicate("x ", 40) <> "alpha delta gamma"

      {:textmod, segments} = JSONDiff.compute_diff(left, right)

      Enum.each(segments, fn seg -> refute seg.text == "" end)
      # No two adjacent segments share the same op (otherwise they'd
      # have been merged).
      pairs = Enum.zip(segments, tl(segments))
      assert Enum.all?(pairs, fn {a, b} -> a.op != b.op end)
    end

    test "adjacent same-op segments coalesce instead of producing one span per token" do
      # A primitive value type-change shows up as a :mod (different
      # types). Force textmod by padding past the threshold with shared
      # prefix/suffix and replacing a chunk in the middle with text that
      # has no shared whitespace tokens with the original.
      left = String.duplicate("a", 40) <> "x onetwothree y" <> String.duplicate("z", 40)
      right = String.duplicate("a", 40) <> "x fourfivesix y" <> String.duplicate("z", 40)

      {:textmod, segments} = JSONDiff.compute_diff(left, right)

      # No two adjacent segments share the same op — the coalescer
      # would have merged them.
      pairs = Enum.zip(segments, tl(segments))
      assert Enum.all?(pairs, fn {a, b} -> a.op != b.op end)
    end

    test "string just under the threshold stays a plain mod" do
      # `@text_diff_min_length` is 60 — both sides under it pick :mod.
      left = String.duplicate("a", 59)
      right = String.duplicate("b", 59)
      assert match?({:mod, _, _}, JSONDiff.compute_diff(left, right))
    end

    test "string at the threshold flips to textmod" do
      # Right hand side bumps past 60 → textmod.
      left = String.duplicate("a", 30) <> " " <> String.duplicate("b", 31)
      right = String.duplicate("a", 30) <> " " <> String.duplicate("c", 31)
      assert match?({:textmod, _}, JSONDiff.compute_diff(left, right))
    end

    test "text-diff preserves newlines as their own tokens" do
      left = String.duplicate("x", 40) <> "\npara1\n\npara2"
      right = String.duplicate("x", 40) <> "\npara1 edited\n\npara2"
      {:textmod, segments} = JSONDiff.compute_diff(left, right)

      # Each `\n` (and the `\n\n` paragraph break) survives as an
      # :eq segment so the rendered output keeps the original spacing.
      text = segments |> Enum.map(& &1.text) |> Enum.join()
      assert text =~ "\n\n"
    end

    test "unicode strings are tokenised by grapheme-aware whitespace" do
      # Non-ASCII letters survive intact through diff + render.
      left = String.duplicate("a", 30) <> " naïve résumé " <> String.duplicate("z", 30)
      right = String.duplicate("a", 30) <> " clever résumé " <> String.duplicate("z", 30)

      {:textmod, segments} = JSONDiff.compute_diff(left, right)
      text = segments |> Enum.map(& &1.text) |> Enum.join()
      assert text =~ "résumé"
      assert text =~ "naïve"
      assert text =~ "clever"
    end
  end

  describe "tokenize/1" do
    test "splits on whitespace runs while preserving them" do
      assert JSONDiff.tokenize("foo bar") == ["foo", " ", "bar"]
      assert JSONDiff.tokenize("a  b") == ["a", "  ", "b"]
      assert JSONDiff.tokenize("a\nb\tc") == ["a", "\n", "b", "\t", "c"]
    end

    test "empty string yields no tokens" do
      assert JSONDiff.tokenize("") == []
    end

    test "single-token string is one token" do
      assert JSONDiff.tokenize("abc") == ["abc"]
    end
  end

  describe "lcs_pairs/2" do
    test "identical runs align at every position" do
      assert JSONDiff.lcs_pairs(["a", "b", "c"], ["a", "b", "c"]) == [
               {0, 0},
               {1, 1},
               {2, 2}
             ]
    end

    test "middle mismatch produces matches at the bookends" do
      assert JSONDiff.lcs_pairs(["a", "b", "c"], ["a", "x", "c"]) == [{0, 0}, {2, 2}]
    end

    test "no overlap produces no pairs" do
      assert JSONDiff.lcs_pairs([1, 2, 3], [4, 5, 6]) == []
    end

    test "empty input is safe" do
      assert JSONDiff.lcs_pairs([], [1]) == []
      assert JSONDiff.lcs_pairs([1], []) == []
      assert JSONDiff.lcs_pairs([], []) == []
    end
  end

  # ---------- pretty ----------

  describe "pretty/1" do
    test "primitives stringify via JSON" do
      assert JSONDiff.pretty(1) == "1"
      assert JSONDiff.pretty(true) == "true"
      assert JSONDiff.pretty(nil) == "null"
      assert JSONDiff.pretty("x") == "\"x\""
    end

    test "empty containers inline" do
      assert JSONDiff.pretty(%{}) == "{}"
      assert JSONDiff.pretty([]) == "[]"
    end

    test "maps sort keys alphabetically" do
      assert JSONDiff.pretty(%{"b" => 1, "a" => 2}) == ~s({\n  "a": 2,\n  "b": 1\n})
    end

    test "nested structures indent two spaces per level" do
      out = JSONDiff.pretty(%{"a" => %{"b" => [1, 2]}})

      assert out ==
               ~s({\n  "a": {\n    "b": [\n      1,\n      2\n    ]\n  }\n})
    end

    test "strings with quotes, backslashes, newlines, and tabs are JSON-escaped" do
      assert JSONDiff.pretty("a\"b") == ~s("a\\"b")
      assert JSONDiff.pretty("a\\b") == ~s("a\\\\b")
      assert JSONDiff.pretty("a\nb") =~ "\\n"
      assert JSONDiff.pretty("a\tb") =~ "\\t"
    end

    test "list of mixed types serialises each element with proper indent" do
      out = JSONDiff.pretty([1, "x", true, nil, [2]])

      assert out ==
               ~s([\n  1,\n  "x",\n  true,\n  null,\n  [\n    2\n  ]\n])
    end

    test "pretty/1 output round-trips through JSON.decode!" do
      shapes = [
        nil,
        true,
        0,
        1.25,
        "hello",
        [1, "a", false],
        %{"x" => %{"y" => [true, nil, 1]}}
      ]

      for value <- shapes do
        assert value |> JSONDiff.pretty() |> JSON.decode!() == value
      end
    end

    test "non-string keys are stringified before encoding" do
      assert JSONDiff.pretty(%{a: 1}) =~ ~s("a": 1)
      assert JSONDiff.pretty(%{1 => "one"}) =~ ~s("1": "one")
    end
  end

  # ---------- rendering ----------

  describe "diff/1 (function component)" do
    test "deep-equal values render the empty notice" do
      html = render_component(&JSONDiff.diff/1, old: %{"a" => 1}, new: %{"a" => 1})
      assert html =~ ~s(class="json-diff-empty")
      assert html =~ "No changes detected"
    end

    test "object change wraps in the expected root classes" do
      html = render_component(&JSONDiff.diff/1, old: %{"a" => 1}, new: %{"a" => 2})

      assert html =~
               ~s(json-diff-delta json-diff-node json-diff-child-node-type-object)

      assert html =~ ~s(<ul class="json-diff-node json-diff-node-type-object">)
      assert html =~ "json-diff-left-value"
      assert html =~ "json-diff-right-value"
    end

    test "insert (nil left) renders the whole right as added" do
      html =
        render_component(&JSONDiff.diff/1,
          old: nil,
          new: %{"id" => "x", "name" => "alice"}
        )

      assert html =~ "json-diff-added"
      assert html =~ "alice"
    end

    test "delete (nil right) renders the whole left as deleted" do
      html =
        render_component(&JSONDiff.diff/1,
          old: %{"id" => "x", "name" => "bob"},
          new: nil
        )

      assert html =~ "json-diff-deleted"
      assert html =~ "bob"
    end

    test "nested object changes carry the child-node-type class" do
      html =
        render_component(&JSONDiff.diff/1,
          old: %{"id" => "x", "config" => %{"a" => 1}},
          new: %{"id" => "x", "config" => %{"a" => 2}}
        )

      assert html =~ "json-diff-child-node-type-object"
      assert html =~ "json-diff-modified"
    end

    test "nested arrays carry the array kind class" do
      html =
        render_component(&JSONDiff.diff/1,
          old: %{"items" => [1, 2]},
          new: %{"items" => [1, 3]}
        )

      assert html =~ "json-diff-child-node-type-array"
    end

    test "HTML in keys is escaped" do
      html = render_component(&JSONDiff.diff/1, old: %{"<x>" => "a"}, new: %{"<x>" => "b"})
      assert html =~ "&lt;x&gt;"
      refute html =~ "<x>"
    end

    test "HTML in values is escaped" do
      html =
        render_component(&JSONDiff.diff/1,
          old: %{"name" => "<script>alert(1)</script>"},
          new: %{"name" => "safe"}
        )

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>alert(1)</script>"
    end

    test "long-string change renders textdiff spans inside surrounding quotes" do
      left = String.duplicate("z", 30) <> " brown " <> String.duplicate("y", 30)
      right = String.duplicate("z", 30) <> " red " <> String.duplicate("y", 30)

      html = render_component(&JSONDiff.diff/1, old: %{"k" => left}, new: %{"k" => right})

      assert html =~ "json-diff-textdiff"
      assert html =~ ~s(<span class="json-diff-textdiff-deleted">brown</span>)
      assert html =~ ~s(<span class="json-diff-textdiff-added">red</span>)
      # quotes wrap the segment block; the body span carries its own
      # class so CSS can target multi-line text-diff layout without
      # clobbering the marker class on the parent <li>.
      assert html =~ ~s(<span class="json-diff-textdiff-body">")
    end

    test "added array item gets type class for nested rendering" do
      html =
        render_component(&JSONDiff.diff/1,
          old: %{"items" => []},
          new: %{"items" => [%{"id" => "x"}]}
        )

      assert html =~ "json-diff-added"
      assert html =~ "json-diff-child-node-type-object"
    end

    test "top-level array diff renders with array node type" do
      html = render_component(&JSONDiff.diff/1, old: [1, 2, 3], new: [1, 2, 4])

      assert html =~ ~s(json-diff-child-node-type-array)
      assert html =~ ~s(<ul class="json-diff-node json-diff-node-type-array">)
    end

    test "nil to value at a shared key renders cleanly as added (no crash)" do
      # Regression: this exact shape used to blow up `render_child/1`
      # because no clause matched `{state: :changed, delta: {:add, _}}`.
      html =
        render_component(&JSONDiff.diff/1,
          old: %{"ip_stack" => nil, "name" => "x"},
          new: %{"ip_stack" => "dual", "name" => "x"}
        )

      assert html =~ "json-diff-added"
      assert html =~ "dual"
    end

    test "render is deterministic regardless of input key order" do
      html_a = render_component(&JSONDiff.diff/1, old: %{"a" => 1, "z" => 2}, new: %{"a" => 9, "z" => 2})
      html_b = render_component(&JSONDiff.diff/1, old: %{"z" => 2, "a" => 1}, new: %{"z" => 2, "a" => 9})

      assert html_a == html_b
    end

    test "top-level primitive modification renders without crashing" do
      html = render_component(&JSONDiff.diff/1, old: 1, new: 2)
      assert html =~ "json-diff-modified"
      assert html =~ "json-diff-left-value"
      assert html =~ "json-diff-right-value"
    end

    test "top-level long-string modification renders as textmod" do
      left = String.duplicate("a", 40) <> " brown " <> String.duplicate("z", 40)
      right = String.duplicate("a", 40) <> " red " <> String.duplicate("z", 40)
      html = render_component(&JSONDiff.diff/1, old: left, new: right)

      assert html =~ "json-diff-textdiff"
      assert html =~ "json-diff-textdiff-deleted"
      assert html =~ "json-diff-textdiff-added"
    end

    test "top-level array diff at the root carries the array kind class" do
      html = render_component(&JSONDiff.diff/1, old: [1, 2, 3], new: [1, 2, 4])
      assert html =~ "json-diff-node-type-array"
    end

    test "deeply nested structural changes recurse through every level" do
      old = %{"a" => %{"b" => %{"c" => %{"d" => [1, 2, 3]}}}}
      new = %{"a" => %{"b" => %{"c" => %{"d" => [1, 2, 4]}}}}
      html = render_component(&JSONDiff.diff/1, old: old, new: new)

      # All four levels should have rendered as nested object nodes.
      assert html =~ ~s(json-diff-property-name">a</div>)
      assert html =~ ~s(json-diff-property-name">b</div>)
      assert html =~ ~s(json-diff-property-name">c</div>)
      assert html =~ ~s(json-diff-property-name">d</div>)
      # And the leaf array change appears as a modified primitive.
      assert html =~ "json-diff-modified"
    end

    test "boolean and null values render correctly in pre blocks" do
      html =
        render_component(&JSONDiff.diff/1,
          old: %{"on" => true, "extra" => nil},
          new: %{"on" => false, "extra" => "now-set"}
        )

      # Boolean change shows true → false in left/right values.
      assert html =~ "true"
      assert html =~ "false"
      # nil-to-value at a shared key promotes to :added (regression
      # path) and renders the new value.
      assert html =~ "now-set"
    end

    test "added array on a key uses the child-node-type-array class" do
      html =
        render_component(&JSONDiff.diff/1,
          old: %{"items" => nil},
          new: %{"items" => [1, 2]}
        )

      assert html =~ "json-diff-added"
      assert html =~ "json-diff-child-node-type-array"
    end

    test "deleted nested object preserves its content as a single pre block" do
      html =
        render_component(&JSONDiff.diff/1,
          old: %{"meta" => %{"a" => 1, "b" => 2}},
          new: %{"meta" => nil}
        )

      assert html =~ "json-diff-deleted"
      assert html =~ "json-diff-child-node-type-object"
      # The original nested map is rendered as a single JSON blob; HEEx
      # HTML-escapes the JSON quotes inside the <pre>, so we assert on
      # the escaped form the browser receives.
      assert html =~ ~s(&quot;a&quot;: 1)
      assert html =~ ~s(&quot;b&quot;: 2)
    end
  end
end
