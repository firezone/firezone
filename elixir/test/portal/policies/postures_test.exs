defmodule Portal.Policies.PosturesTest do
  use ExUnit.Case, async: true

  alias Portal.Policies.Postures
  alias Portal.Policies.Postures.{And, Leaf, Not, Or}

  defp leaf(field, op, value \\ :none) do
    base = %{"field" => field, "op" => op}

    if value == :none do
      base
    else
      Map.put(base, "value", value)
    end
  end

  defp cast!(map) do
    {:ok, postures} = Postures.cast(map)
    postures
  end

  defp cast_error(map) do
    {:error, message: message} = Postures.cast(map)
    message
  end

  defp intune_leaf(op, value \\ :none), do: leaf("intune.compliance_state", op, value)

  describe "cast/1 grammar" do
    test "nil and an existing tree pass through" do
      assert Postures.cast(nil) == {:ok, nil}
      postures = cast!(intune_leaf("is", "compliant"))
      assert Postures.cast(postures) == {:ok, postures}
    end

    test "anything but a map is rejected" do
      assert Postures.cast("intune") == {:error, message: "must be an object"}
      assert Postures.cast([]) == {:error, message: "must be an object"}
    end

    test "the root is a node, so a bare leaf is a tree" do
      assert %Postures{expr: %Leaf{provider: :intune, field: :compliance_state, rows: :any}} =
               cast!(intune_leaf("is", "compliant"))
    end

    test "an empty object is not a node" do
      assert cast_error(%{}) == "must be one of and, or, not, or a leaf with field and op"
    end

    test "rows all and rows any sit on the leaf" do
      assert %Postures{expr: %Leaf{rows: :all}} = cast!(Map.put(intune_leaf("is", "x"), "rows", "all"))
      assert %Postures{expr: %Leaf{rows: :any}} = cast!(Map.put(intune_leaf("is", "x"), "rows", "any"))
    end

    test "rows must be any or all" do
      assert cast_error(Map.put(intune_leaf("is", "x"), "rows", "some")) == "rows: must be \"any\" or \"all\""
      assert cast_error(Map.put(intune_leaf("is", "x"), "rows", 1)) == "rows: must be \"any\" or \"all\""
    end

    test "firezone rejects rows because a device is one row" do
      map = Map.put(leaf("firezone.hostname", "is", "x"), "rows", "any")
      assert cast_error(map) == "rows: is not allowed, a device is one row"
    end

    test "fields are qualified by provider" do
      assert cast_error(leaf("compliance_state", "is", "x")) ==
               "field: must be provider.field, such as intune.compliance_state"

      assert cast_error(leaf("jamf.serial", "is", "x")) == "field: unknown provider jamf"
      assert cast_error(leaf(".serial", "is", "x")) == "field: unknown provider "
      assert cast_error(leaf(1, "is", "x")) == "field: must be a string"
    end

    test "and, or and not nest, with providers anywhere in the tree" do
      map = %{
        "and" => [
          leaf("intune.compliance_state", "is", "compliant"),
          %{"or" => [leaf("iru.mdm_enabled", "is", true), %{"not" => leaf("firezone.attested", "is", true)}]}
        ]
      }

      assert %Postures{
               expr: %And{
                 nodes: [
                   %Leaf{provider: :intune, field: :compliance_state},
                   %Or{nodes: [%Leaf{provider: :iru, field: :mdm_enabled}, %Not{node: %Leaf{provider: :firezone}}]}
                 ]
               }
             } = cast!(map)
    end

    test "and and or need a non-empty list" do
      assert cast_error(%{"and" => []}) == "and: must be a non-empty list"
      assert cast_error(%{"or" => "x"}) == "or: must be a non-empty list"
    end

    test "a node must be an object with one known shape" do
      assert cast_error(%{"and" => [], "or" => []}) == "must be one of and, or, not, or a leaf with field and op"
      assert cast_error(%{"field" => "intune.compliance_state"}) == "must be one of and, or, not, or a leaf with field and op"
      assert cast_error(%{"and" => [1]}) == "and[0]: must be an object"
      assert cast_error(%{"not" => "x"}) == "not: must be an object"
    end

    test "errors name the path to the offending node" do
      map = %{"and" => [intune_leaf("is", "x"), %{"not" => %{"or" => [%{"x" => 1}]}}]}
      assert cast_error(map) == "and[1].not.or[0]: must be one of and, or, not, or a leaf with field and op"
      assert cast_error(%{"or" => [intune_leaf("is", 1)]}) == "or[0].value: must be a string"
    end

    test "leaves reject unknown keys" do
      assert cast_error(Map.put(intune_leaf("is", "x"), "extra", 1)) == "unknown keys extra"
      assert cast_error(%{"not" => Map.put(intune_leaf("is", "x"), "extra", 1)}) == "not: unknown keys extra"
    end

    test "leaves need a known field of the provider" do
      assert cast_error(leaf("intune.nope", "is", "x")) == "field: intune has no field nope"
      assert cast_error(leaf("intune.account_id", "is", "x")) == "field: intune has no field account_id"
      assert cast_error(leaf("intune.", "is", "x")) == "field: intune has no field "
    end

    test "leaves need an operator that applies to the field type" do
      assert cast_error(leaf("intune.is_encrypted", "contains", "x")) ==
               "op: contains does not apply to a boolean field"

      assert cast_error(leaf("intune.is_encrypted", "like", "x")) == "op: like does not apply to a boolean field"
      assert cast_error(leaf("intune.is_encrypted", 1, "x")) == "op: must be a string"
    end

    test "depth is limited" do
      nested = Enum.reduce(1..10, intune_leaf("is", "x"), fn _i, inner -> %{"not" => inner} end)
      assert cast!(nested) |> Postures.depth() == 10
      assert cast_error(%{"not" => nested}) =~ "nests deeper than 10 levels"
    end

    test "leaves are limited across the whole tree" do
      intune = List.duplicate(intune_leaf("is", "x"), 50)
      iru = List.duplicate(leaf("iru.mdm_enabled", "is", true), 50)
      map = %{"or" => [%{"and" => intune}, %{"and" => iru}]}
      assert cast!(map) |> Postures.leaf_count() == 100

      map = %{"or" => [%{"and" => intune}, %{"and" => [leaf("firezone.attested", "is", true) | iru]}]}
      assert cast_error(map) == "must have at most 100 leaves, has 101"
    end
  end

  describe "cast/1 values" do
    test "exists and does_not_exist take no value" do
      assert %Postures{expr: %Leaf{op: :exists, parsed: nil, value: nil}} = cast!(intune_leaf("exists"))
      assert %Postures{expr: %Leaf{op: :does_not_exist}} = cast!(intune_leaf("does_not_exist"))
      assert cast_error(intune_leaf("exists", "x")) == "value: exists takes no value"
    end

    test "every other operator needs a value" do
      assert cast_error(intune_leaf("is")) == "value: is required"
    end

    test "strings are bounded, non-empty, valid UTF-8, and stored downcased" do
      assert %Postures{expr: %Leaf{value: "Compliant", parsed: "compliant"}} = cast!(intune_leaf("is", "Compliant"))
      assert cast_error(intune_leaf("is", 1)) == "value: must be a string"
      assert cast_error(intune_leaf("is", "")) == "value: must not be empty"
      assert cast_error(intune_leaf("is", <<0xFF>>)) == "value: must be valid UTF-8"
      assert cast_error(intune_leaf("is", String.duplicate("a", 1025))) == "value: must be at most 1024 bytes"

      for op <- ~w[is_not contains does_not_contain starts_with ends_with] do
        assert %Postures{} = cast!(intune_leaf(op, "x"))
      end
    end

    test "string lists are bounded and non-empty" do
      assert %Postures{expr: %Leaf{parsed: ["a", "b"]}} = cast!(intune_leaf("is_in", ["A", "b"]))
      assert %Postures{} = cast!(intune_leaf("is_not_in", ["a"]))
      assert cast_error(intune_leaf("is_in", "a")) == "value: must be a list"
      assert cast_error(intune_leaf("is_in", [])) == "value: must not be empty"
      assert cast_error(intune_leaf("is_in", ["a", 1])) == "value[1]: must be a string"
      assert cast_error(intune_leaf("is_in", List.duplicate("a", 101))) == "value: must have at most 100 items"
    end

    test "regexes must compile and are bounded" do
      assert %Postures{expr: %Leaf{op: :matches, parsed: "^comp"}} = cast!(intune_leaf("matches", "^comp"))
      assert %Postures{} = cast!(intune_leaf("does_not_match", "x$"))
      assert cast_error(intune_leaf("matches", "(")) =~ "value: invalid regex,"
      assert cast_error(intune_leaf("matches", String.duplicate("a", 257))) == "value: must be at most 256 bytes"
      assert cast_error(intune_leaf("matches", 1)) == "value: must be a string"
    end

    test "booleans" do
      assert %Postures{expr: %Leaf{type: :boolean, parsed: true}} = cast!(leaf("intune.is_encrypted", "is", true))
      assert cast_error(leaf("intune.is_encrypted", "is", "true")) == "value: must be true or false"
    end

    test "integers" do
      assert %Postures{expr: %Leaf{type: :integer, parsed: 1024}} =
               cast!(leaf("intune.free_storage_space_bytes", "gte", 1024))

      assert cast_error(leaf("intune.free_storage_space_bytes", "gte", 1.5)) == "value: must be an integer"
      assert cast_error(leaf("intune.free_storage_space_bytes", "gte", "1")) == "value: must be an integer"

      for op <- ~w[eq ne gt lt lte] do
        assert %Postures{} = cast!(leaf("intune.free_storage_space_bytes", op, 1))
      end
    end

    test "floats accept any number" do
      assert %Postures{expr: %Leaf{type: :float, parsed: 128.0}} = cast!(leaf("iru.device_capacity_gb", "gt", 128))
      assert %Postures{} = cast!(leaf("iru.device_capacity_gb", "lt", 0.5))
      assert cast_error(leaf("iru.device_capacity_gb", "gt", "128")) == "value: must be a number"
    end

    test "versions parse into segments" do
      assert %Postures{expr: %Leaf{type: :version, parsed: [10, 0, 19045]}} =
               cast!(leaf("intune.os_version", "gte", "10.0.19045"))

      assert cast_error(leaf("intune.os_version", "gte", "beta")) == "value: must be a version such as 14.4.1"
      assert cast_error(leaf("intune.os_version", "gte", 10)) == "value: must be a string"

      for op <- ~w[is is_not gt lt lte] do
        assert %Postures{} = cast!(leaf("intune.os_version", op, "1"))
      end
    end

    test "datetimes" do
      assert %Postures{expr: %Leaf{type: :datetime, parsed: ~U[2026-01-01 00:00:00Z]}} =
               cast!(leaf("intune.last_sync_at", "after", "2026-01-01T00:00:00Z"))

      assert %Postures{} = cast!(leaf("intune.last_sync_at", "before", "2026-01-01T00:00:00+02:00"))
      assert cast_error(leaf("intune.last_sync_at", "after", "2026-01-01")) == "value: must be an ISO 8601 datetime"
      assert cast_error(leaf("intune.last_sync_at", "after", 1)) == "value: must be a string"
    end

    test "durations must be positive ISO 8601" do
      assert %Postures{expr: %Leaf{parsed: %Duration{hour: 24}}} = cast!(leaf("intune.last_sync_at", "within_last", "PT24H"))
      assert %Postures{} = cast!(leaf("intune.last_sync_at", "not_within_last", "P7D"))
      assert %Postures{} = cast!(leaf("intune.android_security_patch_level", "within_last", "P90D"))

      for bad <- ["24h", "PT0S", "PT-1H", "P1D-PT1H"] do
        assert cast_error(leaf("intune.last_sync_at", "within_last", bad)) ==
                 "value: must be a positive ISO 8601 duration such as PT24H"
      end

      assert cast_error(leaf("intune.last_sync_at", "within_last", 24)) == "value: must be a string"
    end

    test "date columns take datetimes, so a calendar date is converted before it gets here" do
      assert %Postures{expr: %Leaf{type: :datetime, parsed: ~U[2026-01-01 00:00:00Z]}} =
               cast!(leaf("intune.android_security_patch_level", "after", "2026-01-01T00:00:00Z"))

      assert cast_error(leaf("intune.android_security_patch_level", "after", "2026-01-01")) ==
               "value: must be an ISO 8601 datetime"
    end

    test "cidrs parse with a default netmask" do
      map = leaf("defender.last_ip_address", "is_in_cidr", ["10.0.0.0/8", "192.168.1.1", "2001:db8::/32"])

      assert %Postures{
               expr: %Leaf{
                 type: :ip,
                 parsed: [
                   %Postgrex.INET{address: {10, 0, 0, 0}, netmask: 8},
                   %Postgrex.INET{address: {192, 168, 1, 1}, netmask: 32},
                   %Postgrex.INET{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, netmask: 32}
                 ]
               }
             } = cast!(map)

      assert %Postures{} = cast!(leaf("defender.last_ip_address", "is_not_in_cidr", ["::1"]))

      assert cast_error(leaf("defender.last_ip_address", "is_in_cidr", ["office"])) ==
               "value[0]: must be a CIDR such as 10.0.0.0/8"

      assert cast_error(leaf("defender.last_ip_address", "is_in_cidr", [1])) == "value[0]: must be a string"
    end

    test "string arrays" do
      assert %Postures{expr: %Leaf{type: :string_array, parsed: "vip"}} =
               cast!(leaf("defender.machine_tags", "contains", "VIP"))

      assert %Postures{} = cast!(leaf("defender.machine_tags", "does_not_contain", "x"))
      assert %Postures{expr: %Leaf{parsed: ["a", "b"]}} = cast!(leaf("defender.machine_tags", "contains_any_of", ["A", "B"]))
      assert %Postures{} = cast!(leaf("defender.machine_tags", "contains_all_of", ["a"]))
      assert %Postures{expr: %Leaf{op: :is_empty, parsed: nil}} = cast!(leaf("defender.machine_tags", "is_empty"))
      assert %Postures{} = cast!(leaf("defender.machine_tags", "is_not_empty"))
      assert cast_error(leaf("defender.machine_tags", "is_empty", true)) == "value: is_empty takes no value"
    end

    test "json fields only answer emptiness" do
      assert %Postures{expr: %Leaf{type: :json, op: :is_not_empty}} = cast!(leaf("defender.ip_addresses", "is_not_empty"))
      assert cast_error(leaf("defender.ip_addresses", "contains", "x")) == "op: contains does not apply to a json field"
    end

    test "synthetic fields" do
      assert %Postures{expr: %Leaf{field: :enrolled, parsed: false}} = cast!(leaf("intune.enrolled", "is", false))
      assert %Postures{expr: %Leaf{field: :attested, parsed: true}} = cast!(leaf("firezone.attested", "is", true))
    end
  end

  describe "dump/1 and load/1" do
    test "round trip the wire form, including value-less leaves and rows all" do
      map = %{
        "and" => [
          leaf("firezone.last_seen_version", "gte", "1.5.10"),
          %{
            "or" => [
              Map.put(leaf("intune.compliance_state", "is", "Compliant"), "rows", "all"),
              %{"not" => leaf("intune.notes", "exists")},
              leaf("intune.last_sync_at", "within_last", "PT24H")
            ]
          },
          leaf("defender.last_ip_address", "is_in_cidr", ["10.0.0.0/8"])
        ]
      }

      postures = cast!(map)
      assert {:ok, dumped} = Postures.dump(postures)
      assert dumped == map
      assert Postures.to_map(postures) == map
      assert {:ok, loaded} = Postures.load(dumped)
      assert loaded == postures
      assert Postures.equal?(loaded, postures)
    end

    test "nil round trips" do
      assert Postures.dump(nil) == {:ok, nil}
      assert Postures.load(nil) == {:ok, nil}
    end

    test "rows any is written in the short form" do
      postures = cast!(Map.put(intune_leaf("is", "x"), "rows", "any"))
      assert Postures.to_map(postures) == intune_leaf("is", "x")
    end

    test "load rejects what cast rejects, and non-maps" do
      assert Postures.load(leaf("jamf.x", "is", "y")) == :error
      assert Postures.load("x") == :error
      assert Postures.dump("x") == :error
    end

    test "the type is a map embedded as itself" do
      assert Postures.type() == :map
      assert Postures.embed_as(:json) == :self
      refute Postures.equal?(cast!(intune_leaf("is", "a")), cast!(intune_leaf("is", "b")))
    end
  end

  describe "helpers" do
    test "depth/1 and leaf_count/1 on a bare leaf" do
      assert Postures.depth(cast!(intune_leaf("is", "x"))) == 0
      assert Postures.leaf_count(cast!(intune_leaf("is", "x"))) == 1
      assert Postures.max_depth() == 10
      assert Postures.max_leaves() == 100
    end

    test "depth/1 is the deepest branch" do
      map = %{"and" => [intune_leaf("is", "x"), %{"or" => [leaf("intune.notes", "exists")]}, leaf("iru.mdm_enabled", "is", true)]}
      assert Postures.depth(cast!(map)) == 2
    end

    test "parse_version/1 and compare_versions/2" do
      assert Postures.parse_version("14.4.1") == [14, 4, 1]
      assert Postures.parse_version("10.0.19045 (21H2)") == [10, 0, 19045, 21, 2]
      assert Postures.parse_version("v2026.7") == [2026, 7]
      assert Postures.parse_version("beta") == []
      assert Postures.compare_versions([14, 4], [14, 4, 0]) == :eq
      assert Postures.compare_versions([14, 4, 1], [14, 4]) == :gt
      assert Postures.compare_versions([14, 3, 9], [14, 4]) == :lt
      assert Postures.compare_versions([1, 10], [1, 9]) == :gt
    end

    test "safe_match?/2 matches, misses, and gives up on a pathological pattern" do
      assert Postures.safe_match?("^comp", "compliant")
      refute Postures.safe_match?("^comp", "noncompliant")
      refute Postures.safe_match?("^(a+)+$", String.duplicate("a", 40) <> "b")
    end
  end
end
