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
    assert Postures.maybe_drop_unsupported(attrs, %{availability: :hidden}) == %{"description" => "x"}
  end
end
