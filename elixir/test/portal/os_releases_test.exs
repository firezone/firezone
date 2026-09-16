defmodule Portal.OSReleasesTest do
  use Portal.DataCase, async: true

  alias Portal.{OSRelease, OSReleases}

  setup do
    table = :ets.new(:"os_releases_#{System.unique_integer([:positive])}", [:set, :public])
    put(table, :macos, "15", "15.6.1", true)
    put(table, :macos, "13", "13.7.6", false)
    put(table, :ios, "18", "18.6", true)
    put(table, :windows, "10.0.26100", "10.0.26100.4652", true)
    put(table, :windows, "10.0.19045", "10.0.19045.6093", false)
    put(table, :linux, "6.12", "6.12.34", true)
    %{table: table}
  end

  defp put(table, os, line, latest, supported?) do
    release = %OSRelease{os: os, line: line, latest_version: latest, supported: supported?, fetched_at: DateTime.utc_now()}
    :ets.insert(table, {{os, line}, release})
  end

  test "line_for/2 places a version on its release line" do
    assert OSReleases.line_for(:windows, [10, 0, 26100, 4652]) == "10.0.26100"
    assert OSReleases.line_for(:windows, [11]) == nil
    assert OSReleases.line_for(:macos, [15, 6, 1]) == "15"
    assert OSReleases.line_for(:ios, [18]) == "18"
    assert OSReleases.line_for(:linux, [6, 12, 34]) == "6.12"
    assert OSReleases.line_for(:linux, [6]) == nil
    assert OSReleases.line_for(:macos, []) == nil
  end

  test "up_to_date?/3 is true only on the newest patch of a supported line", %{table: table} do
    assert OSReleases.up_to_date?(:macos, "15.6.1", table)
    assert OSReleases.up_to_date?(:macos, "15.7", table)
    refute OSReleases.up_to_date?(:macos, "15.6", table)
    refute OSReleases.up_to_date?(:macos, "13.7.6", table), "an unsupported line is never up to date"
    refute OSReleases.up_to_date?(:macos, "14.7.6", table), "a line the feed does not list is not supported"
    assert OSReleases.up_to_date?(:windows, "10.0.26100.4652", table)
    refute OSReleases.up_to_date?(:windows, "10.0.26100.2894", table)
    refute OSReleases.up_to_date?(:windows, "10.0.19045.6093", table)
    assert OSReleases.up_to_date?(:linux, "6.12.34", table)
    refute OSReleases.up_to_date?(:linux, "6.12.1", table)
    assert OSReleases.up_to_date?(:macos, "garbage", table) == nil
  end

  test "row_up_to_date?/2 reads the OS and version off each provider's row", %{table: table} do
    assert OSReleases.row_up_to_date?(%Portal.Intune.Device{operating_system: "macOS", os_version: "15.6.1"}, table)
    refute OSReleases.row_up_to_date?(%Portal.Intune.Device{operating_system: "Windows", os_version: "10.0.26100.1000"}, table)
    assert OSReleases.row_up_to_date?(%Portal.Intune.Device{operating_system: "iOS", os_version: "18.6"}, table)
    android = %Portal.Intune.Device{operating_system: "Android", os_version: "15"}
    after_bulletin = ~D[2026-09-15]
    assert OSReleases.row_up_to_date?(%{android | android_security_patch_level: ~D[2026-09-05]}, table, after_bulletin)
    assert OSReleases.row_up_to_date?(%{android | android_security_patch_level: ~D[2026-09-01]}, table, after_bulletin)
    refute OSReleases.row_up_to_date?(%{android | android_security_patch_level: ~D[2026-08-05]}, table, after_bulletin)
    before_bulletin = ~D[2026-09-03]
    assert OSReleases.row_up_to_date?(%{android | android_security_patch_level: ~D[2026-08-05]}, table, before_bulletin)
    refute OSReleases.row_up_to_date?(%{android | android_security_patch_level: ~D[2026-07-05]}, table, before_bulletin)
    assert OSReleases.row_up_to_date?(android, table, after_bulletin) == nil
    assert OSReleases.row_up_to_date?(%Portal.Iru.Device{os_name: "iPadOS", os_version: "18.6"}, table)
    assert OSReleases.row_up_to_date?(%Portal.Defender.Device{os_platform: "macOS", version: "15.6.1"}, table)
    assert OSReleases.row_up_to_date?(%Portal.Santa.Device{os_version: "15.6.1"}, table)
    assert OSReleases.row_up_to_date?(%Portal.SentinelOne.Device{os_type: "macos", os_revision: "15.6.1"}, table)
    assert OSReleases.row_up_to_date?(%Portal.SentinelOne.Device{os_type: "windows", os_revision: "10.0.26100.4652"}, table)

    assert OSReleases.row_up_to_date?(%Portal.Defender.Device{os_platform: "Windows11", version: "24H2"}, table) == nil
    assert OSReleases.row_up_to_date?(%Portal.SentinelOne.Device{os_type: "windows", os_revision: "24H2"}, table) == nil
    assert OSReleases.row_up_to_date?(%Portal.SentinelOne.Device{os_type: "linux", os_revision: "24.04.2 LTS"}, table) == nil
    assert OSReleases.row_up_to_date?(%Portal.Intune.Device{operating_system: nil, os_version: nil}, table) == nil
  end

  test "latest_android_bulletin/1 is this month once its first Monday has passed" do
    assert OSReleases.latest_android_bulletin(~D[2026-09-07]) == ~D[2026-09-01]
    assert OSReleases.latest_android_bulletin(~D[2026-09-06]) == ~D[2026-08-01]
    assert OSReleases.latest_android_bulletin(~D[2026-06-01]) == ~D[2026-06-01]
    assert OSReleases.latest_android_bulletin(~D[2026-01-03]) == ~D[2025-12-01]
  end

  test "refresh/1 mirrors the table into ETS", %{table: table} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%OSRelease{os: :ios, line: "17", latest_version: "17.7.11", supported: true, fetched_at: now})

    :ok = OSReleases.refresh(table)

    assert [{{:ios, "17"}, %OSRelease{latest_version: "17.7.11"}}] = :ets.lookup(table, {:ios, "17"})
    assert :ets.lookup(table, {:macos, "15"}) == [], "a row that is not in the database is dropped"
  end
end
