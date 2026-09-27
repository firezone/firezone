defmodule PortalWeb.Policies.PosturesTest do
  use ExUnit.Case, async: true

  alias PortalWeb.Policies.Postures
  alias PortalWeb.Policies.Postures.Checks

  defp event(state, name, params), do: Postures.handle_event(name, params, state)

  defp cast(wire) do
    {:ok, postures} = Portal.Policies.Postures.cast(wire)
    postures
  end

  defp expansion(name) do
    {:ok, check} = Checks.fetch(name)
    check.expansion
  end

  test "starts with nothing checked and an empty hidden value" do
    state = Postures.new(:enabled)
    assert Postures.checks(state) == {:ok, []}
    assert Postures.hidden_value(state) == ""
    assert state.connected == []
    assert state.trust_anchors?
  end

  test "toggling checks writes their expansions and reads them back" do
    state = Postures.new(:enabled) |> event("postures_toggle_check", %{"name" => "compliant"})
    assert state.wire == expansion(:compliant)
    assert Postures.checks(state) == {:ok, [:compliant]}

    state = event(state, "postures_toggle_check", %{"name" => "disk_encryption"})
    assert state.wire == %{"and" => [expansion(:compliant), expansion(:disk_encryption)]}
    assert Postures.checks(state) == {:ok, [:compliant, :disk_encryption]}
    assert JSON.decode!(Postures.hidden_value(state)) == state.wire

    state = event(state, "postures_toggle_check", %{"name" => "compliant"})
    assert state.wire == expansion(:disk_encryption)

    state = event(state, "postures_toggle_check", %{"name" => "disk_encryption"})
    assert state.wire == nil
    assert Postures.hidden_value(state) == ""

    assert event(state, "postures_toggle_check", %{"name" => "bogus"}) == state
    assert event(state, "postures_something_else", %{}) == state
  end

  test "a saved policy made of checks shows them as toggles" do
    saved = cast(%{"and" => [expansion(:compliant), expansion(:firewall)]})
    state = Postures.new(:enabled, saved)
    assert Postures.checks(state) == {:ok, [:compliant, :firewall]}
    assert Postures.new(:enabled, cast(expansion(:managed))) |> Postures.checks() == {:ok, [:managed]}
  end

  test "a tree the checks cannot express is custom and left alone" do
    custom = cast(%{"not" => expansion(:compliant)})
    state = Postures.new(:enabled, custom)
    assert Postures.checks(state) == :custom
    assert event(state, "postures_toggle_check", %{"name" => "compliant"}) == state
    assert JSON.decode!(Postures.hidden_value(state)) == %{"not" => expansion(:compliant)}

    mixed = cast(%{"and" => [expansion(:compliant), %{"field" => "intune.os_version", "op" => "gte", "value" => "14"}]})
    assert Postures.new(:enabled, mixed) |> Postures.checks() == :custom
  end

  test "checks are available only when a provider that answers them is connected" do
    {:ok, compliant} = Checks.fetch(:compliant)
    {:ok, encryption} = Checks.fetch(:disk_encryption)
    {:ok, client} = Checks.fetch(:client_up_to_date)

    none = Postures.new(:enabled, nil, connected: [])
    refute Postures.check_available?(none, compliant)
    assert Postures.check_available?(none, client)

    iru = Postures.new(:enabled, nil, connected: [:iru])
    refute Postures.check_available?(iru, compliant)
    assert Postures.check_available?(iru, encryption)
  end

  test "maybe_drop_unsupported/2 keeps postures only when enabled" do
    attrs = %{"postures" => "{}", "description" => "x"}
    assert Postures.maybe_drop_unsupported(attrs, %{availability: :enabled}) == attrs
    assert Postures.maybe_drop_unsupported(attrs, %{availability: :locked}) == %{"description" => "x"}
  end

  describe "JSON tab" do
    @compliant %{"field" => "intune.compliance_state", "op" => "is", "value" => "compliant"}
    @custom %{"not" => %{"field" => "intune.jail_broken", "op" => "is", "value" => true}}

    defp saved(wire) do
      {:ok, postures} = Portal.Policies.Postures.cast(wire)
      Postures.new(:enabled, postures)
    end

    defp json(state, text), do: Postures.handle_event("postures_json_change", %{"_postures_json" => text}, state)
    defp tab(state, name), do: Postures.handle_event("postures_tab", %{"tab" => name}, state)

    test "custom rules open on the JSON tab, checks on the Simplified tab" do
      assert saved(@custom).tab == :json
      assert saved(@compliant).tab == :simple
      assert Postures.new(:enabled).tab == :simple
    end

    test "switching to JSON renders the rules with leaf keys in reading order" do
      state = saved(%{"and" => [Map.put(@compliant, "rows", "all")]}) |> tab("json")
      assert state.json_text =~ ~r/"field": "intune.compliance_state",\n\s+"op": "is",\n\s+"value": "compliant",\n\s+"rows": "all"/
      assert Postures.hidden_value(state) == String.trim(state.json_text)
      refute Postures.dirty?(state)
    end

    test "valid JSON becomes the current rules and the toggles follow" do
      state = Postures.new(:enabled) |> tab("json") |> json(JSON.encode!(@compliant))
      assert state.json_error == nil
      assert state.wire == @compliant
      assert Postures.checks(state) == {:ok, [:compliant]}
      assert Postures.dirty?(state)
      refute Postures.blocked?(state)
    end

    test "a syntax error is placed at the offending character and blocks saving" do
      text = ~s({"and": [}\n)
      state = saved(@compliant) |> tab("json") |> json(text)

      assert %{message: ~s(unexpected character "}"), span: {9, 1}} = state.json_error
      assert state.wire == @compliant
      assert Postures.blocked?(state)
      assert Postures.hidden_value(state) == String.trim(text)
    end

    test "a semantic error is placed on the offending value, or the enclosing node when the key is missing" do
      state = Postures.new(:enabled) |> tab("json")

      text = ~s(  {"field": "intune.compliance_state", "op": "is", "value": 12})
      assert %{message: "must be a string", span: {start, 2}} = json(state, text).json_error
      assert String.slice(text, start, 2) == "12"

      text = ~s({"field": "intune.compliance_state", "op": "is"})
      assert %{message: "is required", span: {0, length}} = json(state, text).json_error
      assert length == String.length(text)
    end

    test "leading whitespace shifts the span, unexpected end points at the last character" do
      text = ~s(\n\n{"and": [)
      state = Postures.new(:enabled) |> tab("json") |> json(text)
      assert %{message: "unexpected end of input", span: {start, 1}} = state.json_error
      assert start == String.length(text) - 1
    end

    test "an empty document means no requirement" do
      state = saved(@compliant) |> tab("json") |> json("  \n")
      assert state.json_error == nil
      assert state.wire == nil
      assert Postures.hidden_value(state) == ""
      assert Postures.dirty?(state)
    end

    test "the JSON tab keeps broken text across a tab switch, the Simplified tab keeps the last valid rules" do
      state = saved(@compliant) |> tab("json") |> json(~s({"and": [)) |> tab("simple")
      assert Postures.checks(state) == {:ok, [:compliant]}
      assert Postures.hidden_value(state) == JSON.encode!(@compliant)
      refute Postures.blocked?(state)

      assert tab(state, "json").json_text == ~s({"and": [)
    end

    test "toggling a check rewrites the JSON text" do
      state = Postures.handle_event("postures_toggle_check", %{"name" => "compliant"}, Postures.new(:enabled))
      assert JSON.decode!(state.json_text) == @compliant
    end

    test "reset returns to the saved rules and the tab they can be shown on" do
      state = Postures.handle_event("postures_reset", %{}, saved(@compliant) |> tab("json") |> json(~s({"and": [)))
      assert state.wire == @compliant
      assert state.json_error == nil
      assert JSON.decode!(state.json_text) == @compliant
      assert state.tab == :json
      refute Postures.dirty?(state)

      custom = saved(@custom) |> tab("simple")
      assert Postures.handle_event("postures_reset", %{}, custom).tab == :json
    end
  end
end
