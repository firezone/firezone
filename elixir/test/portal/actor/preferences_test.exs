defmodule Portal.Actor.PreferencesTest do
  use ExUnit.Case, async: true

  alias Portal.Actor.Preferences

  describe "getting_started_changeset/2" do
    test "accepts known values" do
      changeset = Preferences.getting_started_changeset(nil, %{getting_started: "device_mesh"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :getting_started) == :device_mesh
    end

    test "rejects unknown and missing values" do
      refute Preferences.getting_started_changeset(nil, %{getting_started: "nope"}).valid?
      refute Preferences.getting_started_changeset(nil, %{}).valid?
    end

    test "keeps the start page" do
      prefs = %Preferences{start_page: :devices, getting_started: :pending}
      changeset = Preferences.getting_started_changeset(prefs, %{getting_started: :dismissed})

      assert Ecto.Changeset.apply_changes(changeset) ==
               %Preferences{start_page: :devices, getting_started: :dismissed}
    end
  end

  describe "changeset/2" do
    test "does not let the profile form change getting_started" do
      prefs = %Preferences{getting_started: :pending}
      changeset = Preferences.changeset(prefs, %{start_page: "devices", getting_started: "dismissed"})

      assert Ecto.Changeset.apply_changes(changeset).getting_started == :pending
    end
  end
end
