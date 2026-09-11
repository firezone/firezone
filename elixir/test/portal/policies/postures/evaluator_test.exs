defmodule Portal.Policies.Postures.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Portal.Device
  alias Portal.Policies.Postures
  alias Portal.Policies.Postures.Evaluator

  @now ~U[2026-09-04 12:00:00Z]
  @failed {:error, [:postures]}

  defp postures(map) do
    {:ok, postures} = Postures.cast(map)
    postures
  end

  defp leaf(field, op, value \\ :none) do
    base = %{"field" => field, "op" => op}

    if value == :none do
      base
    else
      Map.put(base, "value", value)
    end
  end

  defp all_rows(leaf), do: Map.put(leaf, "rows", "all")

  defp device(attrs \\ []) do
    struct!(%Device{type: :client, posture: %{}, attested?: false}, attrs)
  end

  defp intune(attrs), do: struct!(Portal.Intune.Device, attrs)

  defp evaluate(map, device), do: Evaluator.evaluate(postures(map), device, @now)

  defp pass?(field, op, value, row_attrs) do
    device = device(posture: %{intune: [intune(row_attrs)]})
    evaluate(leaf("intune.#{field}", op, value), device) == {:ok, nil}
  end

  describe "evaluate/3 structure" do
    test "nil postures pass without an expiry" do
      assert Evaluator.evaluate(nil, device(), @now) == {:ok, nil}
    end

    test "a bare leaf at the root passes or fails as one posture" do
      device = device(posture: %{intune: [intune(compliance_state: "compliant")]})
      assert evaluate(leaf("intune.compliance_state", "is", "compliant"), device) == {:ok, nil}
      assert evaluate(leaf("intune.compliance_state", "is", "noncompliant"), device) == @failed
    end

    test "providers mix anywhere in the tree" do
      device = device(posture: %{intune: [intune(compliance_state: "compliant")]}, hostname: "laptop")

      map = %{
        "or" => [
          leaf("sentinelone.enrolled", "is", true),
          %{"and" => [leaf("intune.compliance_state", "is", "compliant"), leaf("firezone.hostname", "is", "laptop")]}
        ]
      }

      assert evaluate(map, device) == {:ok, nil}

      map = %{"and" => [leaf("sentinelone.enrolled", "is", true), leaf("intune.compliance_state", "is", "compliant")]}
      assert evaluate(map, device) == @failed
    end

    test "and passes when every child passes and expires with the first child" do
      device =
        device(
          posture: %{intune: [intune(last_sync_at: ~U[2026-09-04 10:00:00Z], is_encrypted: true)]},
          last_attested_at: ~U[2026-09-04 11:00:00Z]
        )

      map = %{
        "and" => [
          leaf("intune.last_sync_at", "within_last", "PT3H"),
          leaf("firezone.last_attested_at", "within_last", "PT1H30M"),
          leaf("intune.is_encrypted", "is", true)
        ]
      }

      assert evaluate(map, device) == {:ok, ~U[2026-09-04 12:30:00Z]}

      map = %{"and" => [leaf("intune.is_encrypted", "is", true), leaf("intune.is_encrypted", "is", false)]}
      assert evaluate(map, device) == @failed
    end

    test "or passes when any child passes and lives as long as the longest passing child" do
      device = device(posture: %{intune: [intune(last_sync_at: ~U[2026-09-04 11:00:00Z], is_encrypted: false)]})

      map = %{
        "or" => [
          leaf("intune.is_encrypted", "is", true),
          leaf("intune.last_sync_at", "within_last", "PT2H"),
          leaf("intune.last_sync_at", "within_last", "PT5H")
        ]
      }

      assert evaluate(map, device) == {:ok, ~U[2026-09-04 16:00:00Z]}
    end

    test "or never expires when a passing child never expires" do
      device = device(posture: %{intune: [intune(last_sync_at: ~U[2026-09-04 11:00:00Z], is_encrypted: true)]})
      map = %{"or" => [leaf("intune.is_encrypted", "is", true), leaf("intune.last_sync_at", "within_last", "PT2H")]}
      assert evaluate(map, device) == {:ok, nil}
    end

    test "or fails when no child passes" do
      device = device(posture: %{intune: [intune(is_encrypted: false)]})
      map = %{"or" => [leaf("intune.is_encrypted", "is", true), leaf("intune.notes", "exists")]}
      assert evaluate(map, device) == @failed
    end

    test "not inverts and drops the expiry" do
      device = device(posture: %{intune: [intune(last_sync_at: ~U[2026-09-04 11:00:00Z])]})
      assert evaluate(%{"not" => leaf("intune.last_sync_at", "within_last", "PT2H")}, device) == @failed
      assert evaluate(%{"not" => leaf("intune.last_sync_at", "within_last", "PT10M")}, device) == {:ok, nil}
    end

    test "a leaf passes when any row passes and lives as long as the longest" do
      rows = [
        intune(compliance_state: "noncompliant", last_sync_at: ~U[2026-09-04 11:00:00Z]),
        intune(compliance_state: "compliant", last_sync_at: ~U[2026-09-04 11:30:00Z]),
        intune(compliance_state: "compliant", last_sync_at: ~U[2026-09-04 11:15:00Z])
      ]

      device = device(posture: %{intune: rows})

      map = %{"and" => [leaf("intune.compliance_state", "is", "compliant"), leaf("intune.last_sync_at", "within_last", "PT2H")]}
      assert evaluate(map, device) == {:ok, ~U[2026-09-04 13:30:00Z]}

      assert evaluate(leaf("intune.compliance_state", "is", "conflict"), device) == @failed
    end

    test "rows all needs every row to pass and expires with the first" do
      rows = [
        intune(compliance_state: "compliant", last_sync_at: ~U[2026-09-04 11:00:00Z]),
        intune(compliance_state: "compliant", last_sync_at: ~U[2026-09-04 11:30:00Z])
      ]

      device = device(posture: %{intune: rows})

      map = %{
        "and" => [
          all_rows(leaf("intune.compliance_state", "is", "compliant")),
          all_rows(leaf("intune.last_sync_at", "within_last", "PT2H"))
        ]
      }

      assert evaluate(map, device) == {:ok, ~U[2026-09-04 13:00:00Z]}

      device = device(posture: %{intune: [intune(compliance_state: "noncompliant") | rows]})
      assert evaluate(map, device) == @failed
    end

    test "each leaf picks its rows on its own" do
      rows = [
        intune(compliance_state: "compliant", last_sync_at: ~U[2026-01-01 00:00:00Z]),
        intune(compliance_state: "noncompliant", last_sync_at: ~U[2026-09-04 11:00:00Z])
      ]

      device = device(posture: %{intune: rows})

      fresh = leaf("intune.last_sync_at", "within_last", "PT2H")
      compliant = leaf("intune.compliance_state", "is", "compliant")
      assert evaluate(%{"and" => [compliant, fresh]}, device) == {:ok, ~U[2026-09-04 13:00:00Z]}
      assert evaluate(%{"and" => [all_rows(compliant), fresh]}, device) == @failed
    end

    test "a leaf whose provider has no rows runs against an empty row, for both row modes" do
      device = device()
      assert evaluate(leaf("intune.compliance_state", "is", "compliant"), device) == @failed
      assert evaluate(all_rows(leaf("intune.compliance_state", "is", "compliant")), device) == @failed
      assert evaluate(leaf("intune.compliance_state", "does_not_exist"), device) == {:ok, nil}
      assert evaluate(leaf("intune.enrolled", "is", false), device) == {:ok, nil}
      assert evaluate(leaf("intune.enrolled", "is", true), device) == @failed

      map = %{"or" => [leaf("intune.compliance_state", "is", "compliant"), leaf("intune.enrolled", "is", false)]}
      assert evaluate(map, device) == {:ok, nil}
    end

    test "enrolled is true when a row matched" do
      device = device(posture: %{intune: [intune([])]})
      assert evaluate(leaf("intune.enrolled", "is", true), device) == {:ok, nil}
    end

    test "firezone reads the device itself, including the live attested flag" do
      device = device(hostname: "Laptop", attested?: true)
      assert evaluate(leaf("firezone.hostname", "is", "laptop"), device) == {:ok, nil}
      assert evaluate(leaf("firezone.attested", "is", true), device) == {:ok, nil}
      assert evaluate(leaf("firezone.attested", "is", false), device) == @failed
    end
  end

  describe "evaluate/3 null fields" do
    test "fail every operator except does_not_exist" do
      refute pass?("compliance_state", "is", "compliant", [])
      refute pass?("compliance_state", "is_not", "compliant", [])
      refute pass?("compliance_state", "does_not_contain", "x", [])
      refute pass?("is_encrypted", "is", false, [])
      refute pass?("last_sync_at", "not_within_last", "PT1H", [])
      refute pass?("compliance_state", "exists", :none, [])
      assert pass?("compliance_state", "does_not_exist", :none, [])
      assert pass?("compliance_state", "exists", :none, compliance_state: "x")
      refute pass?("compliance_state", "does_not_exist", :none, compliance_state: "x")
    end
  end

  describe "evaluate/3 strings" do
    test "compare case-insensitively" do
      assert pass?("compliance_state", "is", "Compliant", compliance_state: "COMPLIANT")
      refute pass?("compliance_state", "is", "compliant", compliance_state: "noncompliant")
      assert pass?("compliance_state", "is_not", "compliant", compliance_state: "noncompliant")
      refute pass?("compliance_state", "is_not", "compliant", compliance_state: "Compliant")
      assert pass?("compliance_state", "is_in", ["a", "Compliant"], compliance_state: "compliant")
      refute pass?("compliance_state", "is_in", ["a"], compliance_state: "compliant")
      assert pass?("compliance_state", "is_not_in", ["a"], compliance_state: "compliant")
      refute pass?("compliance_state", "is_not_in", ["compliant"], compliance_state: "compliant")
      assert pass?("device_name", "contains", "corp", device_name: "Laptop-CORP-01")
      refute pass?("device_name", "contains", "corp", device_name: "laptop")
      assert pass?("device_name", "does_not_contain", "corp", device_name: "laptop")
      refute pass?("device_name", "does_not_contain", "corp", device_name: "laptop-corp")
      assert pass?("device_name", "starts_with", "lap", device_name: "Laptop")
      refute pass?("device_name", "starts_with", "top", device_name: "Laptop")
      assert pass?("device_name", "ends_with", "top", device_name: "Laptop")
      refute pass?("device_name", "ends_with", "lap", device_name: "Laptop")
    end

    test "regexes run against the downcased value" do
      assert pass?("device_name", "matches", "^lap.*-[0-9]+$", device_name: "Laptop-01")
      refute pass?("device_name", "matches", "^desk", device_name: "Laptop-01")
      assert pass?("device_name", "does_not_match", "^desk", device_name: "Laptop-01")
      refute pass?("device_name", "does_not_match", "^lap", device_name: "Laptop-01")
    end
  end

  describe "evaluate/3 booleans and numbers" do
    test "booleans" do
      assert pass?("is_encrypted", "is", true, is_encrypted: true)
      refute pass?("is_encrypted", "is", true, is_encrypted: false)
    end

    test "integers" do
      assert pass?("free_storage_space_bytes", "eq", 10, free_storage_space_bytes: 10)
      refute pass?("free_storage_space_bytes", "eq", 10, free_storage_space_bytes: 11)
      assert pass?("free_storage_space_bytes", "ne", 10, free_storage_space_bytes: 11)
      refute pass?("free_storage_space_bytes", "ne", 10, free_storage_space_bytes: 10)
      assert pass?("free_storage_space_bytes", "gt", 10, free_storage_space_bytes: 11)
      refute pass?("free_storage_space_bytes", "gt", 10, free_storage_space_bytes: 10)
      assert pass?("free_storage_space_bytes", "gte", 10, free_storage_space_bytes: 10)
      refute pass?("free_storage_space_bytes", "gte", 10, free_storage_space_bytes: 9)
      assert pass?("free_storage_space_bytes", "lt", 10, free_storage_space_bytes: 9)
      refute pass?("free_storage_space_bytes", "lt", 10, free_storage_space_bytes: 10)
      assert pass?("free_storage_space_bytes", "lte", 10, free_storage_space_bytes: 10)
      refute pass?("free_storage_space_bytes", "lte", 10, free_storage_space_bytes: 11)
    end

    test "floats" do
      device = device(posture: %{iru: [struct!(Portal.Iru.Device, device_capacity_gb: 128.0)]})
      assert evaluate(leaf("iru.device_capacity_gb", "gte", 128), device) == {:ok, nil}
      assert evaluate(leaf("iru.device_capacity_gb", "lt", 128), device) == @failed
    end
  end

  describe "evaluate/3 versions" do
    test "compare numerically by segment" do
      assert pass?("os_version", "is", "10.0", os_version: "10.0.0")
      refute pass?("os_version", "is", "10.0", os_version: "10.0.1")
      assert pass?("os_version", "is_not", "10.0", os_version: "10.0.1")
      refute pass?("os_version", "is_not", "10.0", os_version: "10.0")
      assert pass?("os_version", "gt", "10.0.19044", os_version: "10.0.19045")
      refute pass?("os_version", "gt", "10.0.19045", os_version: "10.0.19045")
      assert pass?("os_version", "gte", "10.0.19045", os_version: "10.0.19045")
      refute pass?("os_version", "gte", "10.0.19046", os_version: "10.0.19045")
      assert pass?("os_version", "lt", "10.1", os_version: "10.0.19045")
      refute pass?("os_version", "lt", "10.0", os_version: "10.0.19045")
      assert pass?("os_version", "lte", "10.0.19045", os_version: "10.0.19045")
      refute pass?("os_version", "lte", "10.0.19044", os_version: "10.0.19045")
      assert pass?("os_version", "gte", "1.9", os_version: "1.10")
    end

    test "an unparsable field value fails" do
      refute pass?("os_version", "gte", "1.0", os_version: "unknown")
      refute pass?("os_version", "is_not", "1.0", os_version: "unknown")
    end
  end

  describe "evaluate/3 datetimes" do
    test "before and after are strict" do
      assert pass?("last_sync_at", "before", "2026-09-04T12:00:00Z", last_sync_at: ~U[2026-09-04 11:59:59Z])
      refute pass?("last_sync_at", "before", "2026-09-04T12:00:00Z", last_sync_at: ~U[2026-09-04 12:00:00Z])
      assert pass?("last_sync_at", "after", "2026-09-04T12:00:00Z", last_sync_at: ~U[2026-09-04 12:00:01Z])
      refute pass?("last_sync_at", "after", "2026-09-04T12:00:00Z", last_sync_at: ~U[2026-09-04 12:00:00Z])
    end

    test "within_last passes until the field ages past the window" do
      device = device(posture: %{intune: [intune(last_sync_at: ~U[2026-09-04 10:30:00Z])]})
      assert evaluate(leaf("intune.last_sync_at", "within_last", "PT2H"), device) == {:ok, ~U[2026-09-04 12:30:00Z]}
      assert evaluate(leaf("intune.last_sync_at", "within_last", "PT1H"), device) == @failed
      assert evaluate(leaf("intune.last_sync_at", "within_last", "PT1H30M"), device) == {:ok, ~U[2026-09-04 12:00:00Z]}
    end

    test "not_within_last passes once the field is older than the window" do
      assert pass?("last_sync_at", "not_within_last", "PT1H", last_sync_at: ~U[2026-09-04 10:30:00Z])
      refute pass?("last_sync_at", "not_within_last", "PT2H", last_sync_at: ~U[2026-09-04 10:30:00Z])
    end

    test "future values are within the window" do
      device = device(posture: %{intune: [intune(last_sync_at: ~U[2026-09-05 12:00:00Z])]})
      assert evaluate(leaf("intune.last_sync_at", "within_last", "PT1H"), device) == {:ok, ~U[2026-09-05 13:00:00Z]}
    end
  end

  describe "evaluate/3 dates" do
    test "before and after" do
      assert pass?("android_security_patch_level", "after", "2026-01-01", android_security_patch_level: ~D[2026-01-02])
      refute pass?("android_security_patch_level", "after", "2026-01-01", android_security_patch_level: ~D[2026-01-01])
      assert pass?("android_security_patch_level", "before", "2026-01-01", android_security_patch_level: ~D[2025-12-31])
      refute pass?("android_security_patch_level", "before", "2026-01-01", android_security_patch_level: ~D[2026-01-01])
    end

    test "within_last treats the date as midnight UTC" do
      device = device(posture: %{intune: [intune(android_security_patch_level: ~D[2026-08-05])]})

      assert evaluate(leaf("intune.android_security_patch_level", "within_last", "P90D"), device) ==
               {:ok, ~U[2026-11-03 00:00:00Z]}

      assert evaluate(leaf("intune.android_security_patch_level", "within_last", "P30D"), device) == @failed
      assert evaluate(leaf("intune.android_security_patch_level", "not_within_last", "P30D"), device) == {:ok, nil}
    end
  end

  describe "evaluate/3 ips" do
    test "is_in_cidr and is_not_in_cidr for v4 and v6" do
      v4 = %Postgrex.INET{address: {10, 1, 2, 3}, netmask: nil}
      v6 = %Postgrex.INET{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, netmask: nil}
      device = device(posture: %{defender: [struct!(Portal.Defender.Device, last_ip_address: v4, last_external_ip_address: v6)]})

      assert evaluate(leaf("defender.last_ip_address", "is_in_cidr", ["10.0.0.0/8"]), device) == {:ok, nil}
      assert evaluate(leaf("defender.last_ip_address", "is_in_cidr", ["10.1.2.3"]), device) == {:ok, nil}
      assert evaluate(leaf("defender.last_ip_address", "is_in_cidr", ["192.168.0.0/16"]), device) == @failed
      assert evaluate(leaf("defender.last_ip_address", "is_not_in_cidr", ["192.168.0.0/16"]), device) == {:ok, nil}
      assert evaluate(leaf("defender.last_ip_address", "is_not_in_cidr", ["10.0.0.0/8"]), device) == @failed
      assert evaluate(leaf("defender.last_external_ip_address", "is_in_cidr", ["2001:db8::/32"]), device) == {:ok, nil}
      assert evaluate(leaf("defender.last_external_ip_address", "is_in_cidr", ["10.0.0.0/8"]), device) == @failed
    end

    test "firezone tunnel addresses" do
      device = device(ipv4: %Postgrex.INET{address: {100, 64, 0, 5}, netmask: nil})
      assert evaluate(leaf("firezone.ipv4", "is_in_cidr", ["100.64.0.0/10"]), device) == {:ok, nil}
    end
  end

  describe "evaluate/3 string arrays and json" do
    defp defender(attrs), do: device(posture: %{defender: [struct!(Portal.Defender.Device, attrs)]})

    defp defender_pass?(field, op, value, attrs) do
      evaluate(leaf("defender.#{field}", op, value), defender(attrs)) == {:ok, nil}
    end

    test "string arrays compare elements case-insensitively" do
      assert defender_pass?("machine_tags", "contains", "vip", machine_tags: ["VIP", "eng"])
      refute defender_pass?("machine_tags", "contains", "vip", machine_tags: ["eng"])
      assert defender_pass?("machine_tags", "does_not_contain", "vip", machine_tags: ["eng"])
      refute defender_pass?("machine_tags", "does_not_contain", "vip", machine_tags: ["VIP"])
      assert defender_pass?("machine_tags", "contains_any_of", ["vip", "ops"], machine_tags: ["eng", "OPS"])
      refute defender_pass?("machine_tags", "contains_any_of", ["vip", "ops"], machine_tags: ["eng"])
      assert defender_pass?("machine_tags", "contains_all_of", ["vip", "ops"], machine_tags: ["eng", "OPS", "vip"])
      refute defender_pass?("machine_tags", "contains_all_of", ["vip", "ops"], machine_tags: ["ops"])
      assert defender_pass?("machine_tags", "is_empty", :none, machine_tags: [])
      refute defender_pass?("machine_tags", "is_empty", :none, machine_tags: ["a"])
      assert defender_pass?("machine_tags", "is_not_empty", :none, machine_tags: ["a"])
      refute defender_pass?("machine_tags", "is_not_empty", :none, machine_tags: [])
      refute defender_pass?("machine_tags", "is_empty", :none, [])
    end

    test "json fields answer emptiness only" do
      assert defender_pass?("ip_addresses", "is_empty", :none, ip_addresses: [])
      refute defender_pass?("ip_addresses", "is_empty", :none, ip_addresses: [%{"ipAddress" => "10.0.0.1"}])
      assert defender_pass?("ip_addresses", "is_not_empty", :none, ip_addresses: [%{"ipAddress" => "10.0.0.1"}])
      refute defender_pass?("ip_addresses", "is_not_empty", :none, ip_addresses: [])
      assert defender_pass?("ip_addresses", "exists", :none, ip_addresses: [])
      refute defender_pass?("ip_addresses", "exists", :none, [])

      s1 = device(posture: %{sentinelone: [struct!(Portal.SentinelOne.Device, cloud_providers: %{})]})
      assert evaluate(leaf("sentinelone.cloud_providers", "is_empty"), s1) == {:ok, nil}
    end
  end
end
