defmodule PortalWeb.Policies.PosturesTest do
  use ExUnit.Case, async: true

  alias PortalWeb.Policies.Postures

  @wire %{
    "and" => [
      %{"field" => "intune.jail_broken", "op" => "is", "value" => false},
      %{
        "not" => %{
          "or" => [
            %{"field" => "firezone.hostname", "op" => "is_in", "value" => ["a", "b"]},
            %{"field" => "intune.compliance_state", "op" => "is", "value" => "compliant", "rows" => "all"}
          ]
        }
      }
    ]
  }

  defp state(wire \\ @wire) do
    {:ok, postures} = Portal.Policies.Postures.cast(wire)
    Postures.new(:enabled, postures)
  end

  defp event(state, name, params), do: Postures.handle_event(name, params, state)

  defp leaf_ids(%{children: children}), do: Enum.map(children, & &1.id)

  describe "new/2" do
    test "starts empty without postures" do
      state = Postures.new(:enabled)
      assert state.tree.children == []
      assert Postures.to_wire(state.tree) == nil
      assert Postures.hidden_value(state) == ""
      assert state.errors == %{}
      assert state.last_valid == nil
    end

    test "lifts a tree and lowers it back unchanged" do
      state = state()
      assert Postures.to_wire(state.tree) == @wire
      assert state.last_valid == @wire
      assert JSON.decode!(Postures.hidden_value(state)) == @wire
    end

    test "wraps a bare leaf in a root group and collapses it again" do
      leaf = %{"field" => "intune.jail_broken", "op" => "is", "value" => false}
      state = state(leaf)
      assert [%{kind: :leaf, provider: "intune", field: "jail_broken", value: "false"}] = state.tree.children
      assert Postures.to_wire(state.tree) == leaf
      assert Postures.to_wire(state(%{"not" => leaf}).tree) == %{"not" => leaf}
    end

    test "folds double negation" do
      leaf = %{"field" => "intune.jail_broken", "op" => "is", "value" => false}
      state = state(%{"not" => %{"not" => leaf}})
      assert [%{negated?: false}] = state.tree.children
    end
  end

  describe "builder events" do
    test "adds a rule with a valid default leaf" do
      state = Postures.new(:enabled) |> event("postures_add_rule", %{"id" => "0"})
      assert [%{kind: :leaf, provider: "firezone", op: op}] = state.tree.children
      assert op in Postures.operators("firezone", hd(state.tree.children).field)
      assert state.errors == %{hd(state.tree.children).id => {"value", "must not be empty"}}
      assert Postures.to_wire(state.tree)["field"] =~ ~r/^firezone\./
    end

    test "adds a group that starts with one rule and removes it again" do
      state = Postures.new(:enabled) |> event("postures_add_group", %{"id" => "0"})
      assert [%{kind: :group, op: "and", children: [%{kind: :leaf}]} = group] = state.tree.children

      state = event(state, "postures_remove", %{"id" => to_string(group.id)})
      assert state.tree.children == []
    end

    test "an emptied group is flagged on the group" do
      state = Postures.new(:enabled) |> event("postures_add_group", %{"id" => "0"})
      [%{children: [leaf]} = group] = state.tree.children

      state = event(state, "postures_remove", %{"id" => to_string(leaf.id)})
      assert state.errors == %{group.id => {nil, "must be a non-empty list"}}
    end

    test "never removes the root" do
      state = state() |> event("postures_remove", %{"id" => "0"})
      assert length(state.tree.children) == 2
    end

    test "changes provider and field with operators kept valid" do
      state = state()
      [jail_broken, _group] = leaf_ids(state.tree)

      state = event(state, "postures_change", %{"_postures" => %{to_string(jail_broken) => %{"provider" => "santa"}}})
      [leaf, _group] = state.tree.children
      assert leaf.provider == "santa"
      assert leaf.field in Postures.fields("santa")
      assert leaf.op in Postures.operators("santa", leaf.field)

      state = event(state, "postures_change", %{"_postures" => %{to_string(jail_broken) => %{"field" => "hostname"}}})
      [leaf, _group] = state.tree.children
      assert leaf.field == "hostname"
      assert leaf.op in Postures.operators("santa", "hostname")
      assert state.errors == %{}
    end

    test "maps a value error to the leaf input, also under negation" do
      state = state()
      [jail_broken, _group] = leaf_ids(state.tree)
      change = %{"_postures" => %{to_string(jail_broken) => %{"value" => "maybe"}}}

      assert event(state, "postures_change", change).errors ==
               %{jail_broken => {"value", "must be true or false"}}

      negated = state |> event("postures_toggle_not", %{"id" => to_string(jail_broken)}) |> event("postures_change", change)
      assert negated.errors == %{jail_broken => {"value", "must be true or false"}}
      assert %{"not" => _leaf} = hd(Postures.to_wire(negated.tree)["and"])
    end

    test "maps an error inside a nested group" do
      state = state()
      [_jail_broken, group] = state.tree.children
      [hostname, _compliance] = group.children

      state = event(state, "postures_change", %{"_postures" => %{to_string(hostname.id) => %{"op" => "matches", "value" => "("}}})
      assert [{id, {"value", "invalid regex, " <> _}}] = Map.to_list(state.errors)
      assert id == hostname.id
      assert state.last_valid == @wire
    end

    test "switches and/or and rows" do
      state = state() |> event("postures_set_op", %{"id" => "0", "op" => "or"})
      assert %{"or" => _nodes} = Postures.to_wire(state.tree)

      [jail_broken, _group] = leaf_ids(state.tree)
      state = event(state, "postures_set_rows", %{"id" => to_string(jail_broken), "rows" => "all"})
      assert %{"or" => [%{"rows" => "all"} | _rest]} = Postures.to_wire(state.tree)
    end

    test "list values are chips, so a comma inside a value survives" do
      state = Postures.new(:enabled) |> event("postures_add_rule", %{"id" => "0"})
      [leaf] = state.tree.children
      id = to_string(leaf.id)

      state =
        state
        |> event("postures_change", %{"_postures" => %{id => %{"provider" => "intune"}}})
        |> event("postures_change", %{"_postures" => %{id => %{"field" => "compliance_state"}}})
        |> event("postures_change", %{"_postures" => %{id => %{"op" => "is_in"}}})
        |> event("postures_change", %{"_postures" => %{id => %{"value_input" => " Contoso, Ltd "}}})
        |> event("postures_add_value", %{"id" => id})
        |> event("postures_change", %{"_postures" => %{id => %{"value_input" => "compliant"}}})
        |> event("postures_add_value", %{"id" => id})
        |> event("postures_add_value", %{"id" => id})

      assert Postures.to_wire(state.tree)["value"] == ["Contoso, Ltd", "compliant"]
      assert hd(state.tree.children).value_input == ""
      assert state.errors == %{}

      state = event(state, "postures_remove_value", %{"id" => id, "value" => "compliant"})
      assert Postures.to_wire(state.tree)["value"] == ["Contoso, Ltd"]

      json = event(state, "postures_tab", %{"tab" => "json"})
      builder = event(json, "postures_tab", %{"tab" => "builder"})
      assert hd(builder.tree.children).values == ["Contoso, Ltd"]
    end

    test "a value moves between the single input and the list when the operator changes" do
      state = Postures.new(:enabled) |> event("postures_add_rule", %{"id" => "0"})
      [leaf] = state.tree.children
      id = to_string(leaf.id)

      state =
        state
        |> event("postures_change", %{"_postures" => %{id => %{"provider" => "intune"}}})
        |> event("postures_change", %{"_postures" => %{id => %{"field" => "compliance_state"}}})
        |> event("postures_change", %{"_postures" => %{id => %{"value" => "compliant"}}})
        |> event("postures_change", %{"_postures" => %{id => %{"op" => "is_in"}}})

      assert Postures.to_wire(state.tree)["value"] == ["compliant"]

      state = event(state, "postures_change", %{"_postures" => %{id => %{"op" => "is_not"}}})
      assert Postures.to_wire(state.tree)["value"] == "compliant"
    end

    test "a list error points at the value input" do
      state = Postures.new(:enabled) |> event("postures_add_rule", %{"id" => "0"})
      [leaf] = state.tree.children
      id = to_string(leaf.id)

      state =
        state
        |> event("postures_change", %{"_postures" => %{id => %{"provider" => "intune"}}})
        |> event("postures_change", %{"_postures" => %{id => %{"field" => "compliance_state"}}})
        |> event("postures_change", %{"_postures" => %{id => %{"op" => "is_in"}}})

      assert state.errors == %{leaf.id => {"value", "must not be empty"}}
    end

    test "boolean fields default to true" do
      state = Postures.new(:enabled) |> event("postures_add_rule", %{"id" => "0"})
      [leaf] = state.tree.children
      id = to_string(leaf.id)

      state =
        state
        |> event("postures_change", %{"_postures" => %{id => %{"provider" => "intune"}}})
        |> event("postures_change", %{"_postures" => %{id => %{"field" => "jail_broken"}}})

      assert %{"field" => "intune.jail_broken", "op" => "is", "value" => true} = Postures.to_wire(state.tree)

    end

    test "stops offering groups and rules at the parser limits" do
      state = Postures.new(:enabled)
      assert Postures.can_add_rule?(state, 0)
      assert Postures.can_add_group?(state, 0)

      # The root collapses onto its single child, so ten nested groups put the innermost at depth 9;
      # one more group would push its rule past the limit of 10.
      {state, innermost} =
        Enum.reduce(1..10, {state, 0}, fn _level, {state, parent} ->
          state = event(state, "postures_add_group", %{"id" => to_string(parent)})
          {state, state.next_id - 1}
        end)

      refute Enum.any?(state.errors, fn {_id, {_sub, message}} -> message =~ "nests deeper" end)
      assert Postures.can_add_rule?(state, innermost)
      refute Postures.can_add_group?(state, innermost)

      # A second child at the root un-collapses it and pushes the whole chain one level deeper.
      refute Postures.can_add_rule?(state, 0)
      refute Postures.can_add_group?(state, 0)

      wide = Enum.reduce(1..99, Postures.new(:enabled), fn _index, state -> event(state, "postures_add_rule", %{"id" => "0"}) end)
      assert Postures.can_add_rule?(wide, 0)
      wide = event(wide, "postures_add_rule", %{"id" => "0"})
      refute Postures.can_add_rule?(wide, 0)
      refute Postures.can_add_group?(wide, 0)
    end

    test "ignores unknown ids and events" do
      state = state()
      assert event(state, "postures_remove", %{"id" => "nope"}) == state
      assert event(state, "postures_bogus", %{}) == state
    end
  end

  describe "JSON tab" do
    test "switching renders the tree as pretty JSON with leaf keys in order" do
      state = state() |> event("postures_tab", %{"tab" => "json"})
      assert state.tab == :json
      assert state.json_error == nil
      assert state.json_text =~
               ~r/"field": "intune.compliance_state",\n\s+"op": "is",\n\s+"value": "compliant",\n\s+"rows": "all"/
      assert state.json_text =~ ~s("value": ["a", "b"])
      assert JSON.decode!(state.json_text) == @wire
      assert Postures.hidden_value(state) == String.trim(state.json_text)
    end

    test "flags a semantic error with the span of the offending value" do
      state = state() |> event("postures_tab", %{"tab" => "json"})
      text = String.replace(state.json_text, ~s("compliant"), "12")
      state = event(state, "postures_json_change", %{"_postures_json" => text})

      assert %{message: "must be a string", span: {start, 2}} = state.json_error
      assert String.slice(text, start, 2) == "12"
      assert state.last_valid == @wire
    end

    test "falls back to the enclosing leaf when the key is missing" do
      text = ~s({"field": "intune.compliance_state", "op": "is"})
      state = Postures.new(:enabled) |> event("postures_tab", %{"tab" => "json"}) |> event("postures_json_change", %{"_postures_json" => text})

      assert %{message: "is required", span: {0, length}} = state.json_error
      assert length == String.length(text)
    end

    test "flags a syntax error at the offending character" do
      text = ~s({"and": [}\n)
      state = Postures.new(:enabled) |> event("postures_tab", %{"tab" => "json"}) |> event("postures_json_change", %{"_postures_json" => text})

      assert %{message: ~s(unexpected character "}"), span: {9, 1}} = state.json_error
      assert Postures.hidden_value(state) == String.trim(text)
    end

    test "an empty text means no requirement" do
      state = state() |> event("postures_tab", %{"tab" => "json"}) |> event("postures_json_change", %{"_postures_json" => "  \n"})
      assert state.json_error == nil
      assert state.last_valid == nil
      assert Postures.hidden_value(state) == ""
    end

    test "valid JSON lifts into the builder" do
      leaf = %{"field" => "intune.jail_broken", "op" => "is", "value" => true}

      state =
        Postures.new(:enabled)
        |> event("postures_tab", %{"tab" => "json"})
        |> event("postures_json_change", %{"_postures_json" => JSON.encode!(%{"or" => [leaf, %{"not" => leaf}]})})
        |> event("postures_tab", %{"tab" => "builder"})

      assert state.json_notice == nil
      assert %{op: "or", children: [%{negated?: false}, %{negated?: true}]} = state.tree
      assert state.errors == %{}
    end

    test "unreadable JSON keeps the last valid tree in the builder and the text in the JSON tab" do
      state = state() |> event("postures_tab", %{"tab" => "json"})
      broken = ~s({"and": [)
      state = event(state, "postures_json_change", %{"_postures_json" => broken})

      builder = event(state, "postures_tab", %{"tab" => "builder"})
      assert builder.json_notice =~ "last valid version"
      assert Postures.to_wire(builder.tree) == @wire

      json = event(builder, "postures_tab", %{"tab" => "json"})
      assert json.json_text == broken

      edited = builder |> event("postures_add_rule", %{"id" => "0"}) |> event("postures_tab", %{"tab" => "json"})
      assert edited.json_notice == nil
      assert JSON.decode!(edited.json_text) == Postures.to_wire(edited.tree)
    end

    test "JSON with an unknown shape also falls back" do
      state =
        Postures.new(:enabled)
        |> event("postures_tab", %{"tab" => "json"})
        |> event("postures_json_change", %{"_postures_json" => ~s({"field": "intune.jail_broken", "op": "is", "value": true, "extra": 1})})

      assert %{message: "unknown keys extra"} = state.json_error

      builder = event(state, "postures_tab", %{"tab" => "builder"})
      assert builder.json_notice =~ "last valid version"
      assert builder.tree.children == []
    end

    test "an unknown field survives lifting so the error stays visible" do
      state =
        Postures.new(:enabled)
        |> event("postures_tab", %{"tab" => "json"})
        |> event("postures_json_change", %{"_postures_json" => ~s({"field": "intune.bogus", "op": "is", "value": true})})
        |> event("postures_tab", %{"tab" => "builder"})

      assert builder_leaf = hd(state.tree.children)
      assert builder_leaf.field == "bogus"
      assert state.errors == %{builder_leaf.id => {"field", "intune has no field bogus"}}
    end
  end

  describe "maybe_drop_unsupported/2" do
    test "keeps postures only when enabled" do
      attrs = %{"postures" => "{}", "description" => "x"}
      assert Postures.maybe_drop_unsupported(attrs, %{availability: :enabled}) == attrs
      assert Postures.maybe_drop_unsupported(attrs, %{availability: :locked}) == %{"description" => "x"}
      assert Postures.maybe_drop_unsupported(attrs, %{availability: :hidden}) == %{"description" => "x"}
    end
  end
end
