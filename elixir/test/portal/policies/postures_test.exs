defmodule Portal.Policies.PosturesTest do
  use ExUnit.Case, async: true

  alias Portal.Policies.Postures
  alias Portal.Policies.Postures.{And, Leaf, Not, Or, Provider}

  defp leaf(field, op, value \\ :none) do
    base = %{"field" => field, "op" => op}
    if value == :none, do: base, else: Map.put(base, "value", value)
  end

  defp cast!(map) do
    {:ok, postures} = Postures.cast(map)
    postures
  end

  defp cast_error(map) do
    {:error, message: message} = Postures.cast(map)
    message
  end

  defp intune_leaf(op, value \\ :none), do: %{"intune" => leaf("compliance_state", op, value)}

  describe "cast/1 grammar" do
    test "nil and an existing tree pass through" do
      assert Postures.cast(nil) == {:ok, nil}
      postures = cast!(intune_leaf("is", "compliant"))
      assert Postures.cast(postures) == {:ok, postures}
    end

    test "anything but a map is rejected" do
      assert Postures.cast("intune") == {:error, message: "must be an object keyed by provider"}
      assert Postures.cast([]) == {:error, message: "must be an object keyed by provider"}
    end

    test "an empty map is an empty tree" do
      assert cast!(%{}) == %Postures{providers: %{}}
    end

    test "a bare node is shorthand for rows any" do
      assert %Postures{providers: %{intune: %Provider{rows: :any, expr: %Leaf{}}}} =
               cast!(intune_leaf("is", "compliant"))
    end

    test "rows all wraps an expr" do
      map = %{"intune" => %{"rows" => "all", "expr" => leaf("compliance_state", "is", "compliant")}}
      assert %Postures{providers: %{intune: %Provider{rows: :all, expr: %Leaf{}}}} = cast!(map)
    end

    test "rows defaults to any inside the wrapper" do
      map = %{"intune" => %{"expr" => leaf("compliance_state", "is", "compliant")}}
      assert %Postures{providers: %{intune: %Provider{rows: :any}}} = cast!(map)
    end

    test "rows must be any or all" do
      map = %{"intune" => %{"rows" => "some", "expr" => leaf("compliance_state", "is", "x")}}
      assert cast_error(map) == "intune.rows: must be \"any\" or \"all\""
    end

    test "rows needs an expr" do
      assert cast_error(%{"intune" => %{"rows" => "all"}}) == "intune: rows needs an expr"
    end

    test "firezone rejects rows because a device is one row" do
      map = %{"firezone" => %{"rows" => "any", "expr" => leaf("hostname", "is", "x")}}
      assert cast_error(map) == "firezone: rows is not allowed, a device is one row"
    end

    test "the wrapper rejects unknown keys" do
      map = %{"intune" => %{"expr" => leaf("compliance_state", "is", "x"), "mode" => "all"}}
      assert cast_error(map) == "intune: unknown keys mode"
    end

    test "unknown providers and non-string provider keys are rejected" do
      assert cast_error(%{"jamf" => leaf("serial", "is", "x")}) == "jamf: unknown provider"
      assert cast_error(%{intune: leaf("compliance_state", "is", "x")}) == ":intune: provider must be a string"
    end

    test "and, or and not nest" do
      map = %{
        "intune" => %{
          "and" => [
            leaf("compliance_state", "is", "compliant"),
            %{"or" => [leaf("is_encrypted", "is", true), %{"not" => leaf("jail_broken", "is", true)}]}
          ]
        }
      }

      assert %Postures{
               providers: %{
                 intune: %Provider{
                   expr: %And{nodes: [%Leaf{field: :compliance_state}, %Or{nodes: [%Leaf{}, %Not{node: %Leaf{}}]}]}
                 }
               }
             } = cast!(map)
    end

    test "and and or need a non-empty list" do
      assert cast_error(%{"intune" => %{"and" => []}}) == "intune.and: must be a non-empty list"
      assert cast_error(%{"intune" => %{"or" => "x"}}) == "intune.or: must be a non-empty list"
    end

    test "a node must be an object with one known shape" do
      assert cast_error(%{"intune" => "x"}) == "intune: must be an object"
      assert cast_error(%{"intune" => %{"and" => [], "or" => []}}) ==
               "intune: must be one of and, or, not, or a leaf with field and op"
      assert cast_error(%{"intune" => %{"field" => "compliance_state"}}) ==
               "intune: must be one of and, or, not, or a leaf with field and op"
      assert cast_error(%{"intune" => %{"and" => [1]}}) == "intune.and[0]: must be an object"
    end

    test "errors name the path to the offending node" do
      map = %{"intune" => %{"and" => [leaf("compliance_state", "is", "x"), %{"not" => %{"or" => [%{"x" => 1}]}}]}}
      assert cast_error(map) == "intune.and[1].not.or[0]: must be one of and, or, not, or a leaf with field and op"
    end

    test "leaves reject unknown keys" do
      map = %{"intune" => Map.put(leaf("compliance_state", "is", "x"), "extra", 1)}
      assert cast_error(map) == "intune: unknown keys extra"
    end

    test "leaves need a known field of the provider" do
      assert cast_error(%{"intune" => leaf("nope", "is", "x")}) == "intune.field: intune has no field nope"
      assert cast_error(%{"intune" => leaf("account_id", "is", "x")}) == "intune.field: intune has no field account_id"
      assert cast_error(%{"intune" => leaf(1, "is", "x")}) == "intune.field: must be a string"
    end

    test "leaves need an operator that applies to the field type" do
      assert cast_error(%{"intune" => leaf("is_encrypted", "contains", "x")}) ==
               "intune.op: contains does not apply to a boolean field"
      assert cast_error(%{"intune" => leaf("is_encrypted", "like", "x")}) ==
               "intune.op: like does not apply to a boolean field"
      assert cast_error(%{"intune" => leaf("is_encrypted", 1, "x")}) == "intune.op: must be a string"
    end

    test "depth is limited" do
      nested = Enum.reduce(1..10, leaf("compliance_state", "is", "x"), fn _i, inner -> %{"not" => inner} end)
      assert cast!(%{"intune" => nested}) |> Postures.depth() == 10

      too_deep = %{"not" => nested}
      assert cast_error(%{"intune" => too_deep}) =~ "nests deeper than 10 levels"
    end

    test "leaves are limited across providers" do
      leaves = List.duplicate(leaf("compliance_state", "is", "x"), 50)
      map = %{"intune" => %{"and" => leaves}, "iru" => %{"or" => List.duplicate(leaf("mdm_enabled", "is", true), 50)}}
      assert cast!(map) |> Postures.leaf_count() == 100

      map = put_in(map, ["iru", "or"], List.duplicate(leaf("mdm_enabled", "is", true), 51))
      assert cast_error(map) == "must have at most 100 leaves, has 101"
    end
  end

  describe "cast/1 values" do
    test "exists and does_not_exist take no value" do
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{op: :exists, parsed: nil, value: nil}}}} =
               cast!(intune_leaf("exists"))

      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{op: :does_not_exist}}}} =
               cast!(intune_leaf("does_not_exist"))

      assert cast_error(intune_leaf("exists", "x")) == "intune.value: exists takes no value"
    end

    test "every other operator needs a value" do
      assert cast_error(intune_leaf("is")) == "intune.value: is required"
    end

    test "strings are bounded, non-empty, valid UTF-8, and stored downcased" do
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{value: "Compliant", parsed: "compliant"}}}} =
               cast!(intune_leaf("is", "Compliant"))

      assert cast_error(intune_leaf("is", 1)) == "intune.value: must be a string"
      assert cast_error(intune_leaf("is", "")) == "intune.value: must not be empty"
      assert cast_error(intune_leaf("is", <<0xFF>>)) == "intune.value: must be valid UTF-8"

      assert cast_error(intune_leaf("is", String.duplicate("a", 1025))) ==
               "intune.value: must be at most 1024 bytes"

      for op <- ~w[is_not contains does_not_contain starts_with ends_with] do
        assert %Postures{} = cast!(intune_leaf(op, "x"))
      end
    end

    test "string lists are bounded and non-empty" do
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{parsed: ["a", "b"]}}}} =
               cast!(intune_leaf("is_in", ["A", "b"]))

      assert %Postures{} = cast!(intune_leaf("is_not_in", ["a"]))
      assert cast_error(intune_leaf("is_in", "a")) == "intune.value: must be a list"
      assert cast_error(intune_leaf("is_in", [])) == "intune.value: must not be empty"
      assert cast_error(intune_leaf("is_in", ["a", 1])) == "intune.value[1]: must be a string"

      assert cast_error(intune_leaf("is_in", List.duplicate("a", 101))) ==
               "intune.value: must have at most 100 items"
    end

    test "regexes must compile and are bounded" do
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{op: :matches, parsed: "^comp"}}}} =
               cast!(intune_leaf("matches", "^comp"))

      assert %Postures{} = cast!(intune_leaf("does_not_match", "x$"))
      assert cast_error(intune_leaf("matches", "(")) =~ "intune.value: invalid regex,"
      assert cast_error(intune_leaf("matches", String.duplicate("a", 257))) == "intune.value: must be at most 256 bytes"
      assert cast_error(intune_leaf("matches", 1)) == "intune.value: must be a string"
    end

    test "booleans" do
      map = %{"intune" => leaf("is_encrypted", "is", true)}
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{type: :boolean, parsed: true}}}} = cast!(map)
      assert cast_error(%{"intune" => leaf("is_encrypted", "is", "true")}) == "intune.value: must be true or false"
    end

    test "integers" do
      map = %{"intune" => leaf("free_storage_space_bytes", "gte", 1024)}
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{type: :integer, parsed: 1024}}}} = cast!(map)
      assert cast_error(%{"intune" => leaf("free_storage_space_bytes", "gte", 1.5)}) == "intune.value: must be an integer"
      assert cast_error(%{"intune" => leaf("free_storage_space_bytes", "gte", "1")}) == "intune.value: must be an integer"

      for op <- ~w[eq ne gt lt lte] do
        assert %Postures{} = cast!(%{"intune" => leaf("free_storage_space_bytes", op, 1)})
      end
    end

    test "floats accept any number" do
      map = %{"iru" => leaf("device_capacity_gb", "gt", 128)}
      assert %Postures{providers: %{iru: %Provider{expr: %Leaf{type: :float, parsed: 128.0}}}} = cast!(map)
      assert %Postures{} = cast!(%{"iru" => leaf("device_capacity_gb", "lt", 0.5)})
      assert cast_error(%{"iru" => leaf("device_capacity_gb", "gt", "128")}) == "iru.value: must be a number"
    end

    test "versions parse into segments" do
      map = %{"intune" => leaf("os_version", "gte", "10.0.19045")}
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{type: :version, parsed: [10, 0, 19045]}}}} = cast!(map)
      assert cast_error(%{"intune" => leaf("os_version", "gte", "beta")}) == "intune.value: must be a version such as 14.4.1"
      assert cast_error(%{"intune" => leaf("os_version", "gte", 10)}) == "intune.value: must be a string"

      for op <- ~w[is is_not gt lt lte] do
        assert %Postures{} = cast!(%{"intune" => leaf("os_version", op, "1")})
      end
    end

    test "datetimes" do
      map = %{"intune" => leaf("last_sync_at", "after", "2026-01-01T00:00:00Z")}

      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{type: :datetime, parsed: ~U[2026-01-01 00:00:00Z]}}}} =
               cast!(map)

      assert %Postures{} = cast!(%{"intune" => leaf("last_sync_at", "before", "2026-01-01T00:00:00+02:00")})
      assert cast_error(%{"intune" => leaf("last_sync_at", "after", "2026-01-01")}) == "intune.value: must be an ISO 8601 datetime"
      assert cast_error(%{"intune" => leaf("last_sync_at", "after", 1)}) == "intune.value: must be a string"
    end

    test "durations must be positive ISO 8601" do
      map = %{"intune" => leaf("last_sync_at", "within_last", "PT24H")}
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{parsed: %Duration{hour: 24}}}}} = cast!(map)
      assert %Postures{} = cast!(%{"intune" => leaf("last_sync_at", "not_within_last", "P7D")})
      assert %Postures{} = cast!(%{"intune" => leaf("android_security_patch_level", "within_last", "P90D")})

      for bad <- ["24h", "PT0S", "PT-1H", "P1D-PT1H"] do
        assert cast_error(%{"intune" => leaf("last_sync_at", "within_last", bad)}) ==
                 "intune.value: must be a positive ISO 8601 duration such as PT24H"
      end

      assert cast_error(%{"intune" => leaf("last_sync_at", "within_last", 24)}) == "intune.value: must be a string"
    end

    test "dates" do
      map = %{"intune" => leaf("android_security_patch_level", "after", "2026-01-01")}
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{type: :date, parsed: ~D[2026-01-01]}}}} = cast!(map)
      assert %Postures{} = cast!(%{"intune" => leaf("android_security_patch_level", "before", "2026-01-01")})

      assert cast_error(%{"intune" => leaf("android_security_patch_level", "after", "yesterday")}) ==
               "intune.value: must be an ISO 8601 date"

      assert cast_error(%{"intune" => leaf("android_security_patch_level", "after", 1)}) == "intune.value: must be a string"
    end

    test "cidrs parse with a default netmask" do
      map = %{"defender" => leaf("last_ip_address", "is_in_cidr", ["10.0.0.0/8", "192.168.1.1", "2001:db8::/32"])}

      assert %Postures{
               providers: %{
                 defender: %Provider{
                   expr: %Leaf{
                     type: :ip,
                     parsed: [
                       %Postgrex.INET{address: {10, 0, 0, 0}, netmask: 8},
                       %Postgrex.INET{address: {192, 168, 1, 1}, netmask: 32},
                       %Postgrex.INET{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, netmask: 32}
                     ]
                   }
                 }
               }
             } = cast!(map)

      assert %Postures{} = cast!(%{"defender" => leaf("last_ip_address", "is_not_in_cidr", ["::1"])})

      assert cast_error(%{"defender" => leaf("last_ip_address", "is_in_cidr", ["office"])}) ==
               "defender.value[0]: must be a CIDR such as 10.0.0.0/8"

      assert cast_error(%{"defender" => leaf("last_ip_address", "is_in_cidr", [1])}) == "defender.value[0]: must be a string"
    end

    test "string arrays" do
      assert %Postures{providers: %{defender: %Provider{expr: %Leaf{type: :string_array, parsed: "vip"}}}} =
               cast!(%{"defender" => leaf("machine_tags", "contains", "VIP")})

      assert %Postures{} = cast!(%{"defender" => leaf("machine_tags", "does_not_contain", "x")})
      assert %Postures{providers: %{defender: %Provider{expr: %Leaf{parsed: ["a", "b"]}}}} =
               cast!(%{"defender" => leaf("machine_tags", "contains_any_of", ["A", "B"])})
      assert %Postures{} = cast!(%{"defender" => leaf("machine_tags", "contains_all_of", ["a"])})
      assert %Postures{providers: %{defender: %Provider{expr: %Leaf{op: :is_empty, parsed: nil}}}} =
               cast!(%{"defender" => leaf("machine_tags", "is_empty")})
      assert %Postures{} = cast!(%{"defender" => leaf("machine_tags", "is_not_empty")})
      assert cast_error(%{"defender" => leaf("machine_tags", "is_empty", true)}) == "defender.value: is_empty takes no value"
    end

    test "json fields only answer emptiness" do
      assert %Postures{providers: %{defender: %Provider{expr: %Leaf{type: :json, op: :is_not_empty}}}} =
               cast!(%{"defender" => leaf("ip_addresses", "is_not_empty")})

      assert cast_error(%{"defender" => leaf("ip_addresses", "contains", "x")}) ==
               "defender.op: contains does not apply to a json field"
    end

    test "synthetic fields" do
      assert %Postures{providers: %{intune: %Provider{expr: %Leaf{field: :enrolled, parsed: false}}}} =
               cast!(%{"intune" => leaf("enrolled", "is", false)})

      assert %Postures{providers: %{firezone: %Provider{expr: %Leaf{field: :attested, parsed: true}}}} =
               cast!(%{"firezone" => leaf("attested", "is", true)})
    end
  end

  describe "dump/1 and load/1" do
    test "round trip the wire form, including value-less leaves and rows all" do
      map = %{
        "firezone" => leaf("last_seen_version", "gte", "1.5.10"),
        "intune" => %{
          "rows" => "all",
          "expr" => %{
            "and" => [
              leaf("compliance_state", "is", "Compliant"),
              %{"or" => [leaf("last_sync_at", "within_last", "PT24H"), %{"not" => leaf("notes", "exists")}]}
            ]
          }
        },
        "defender" => leaf("last_ip_address", "is_in_cidr", ["10.0.0.0/8"])
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
      postures = cast!(%{"intune" => %{"rows" => "any", "expr" => leaf("compliance_state", "is", "x")}})
      assert Postures.to_map(postures) == %{"intune" => leaf("compliance_state", "is", "x")}
    end

    test "load rejects what cast rejects, and non-maps" do
      assert Postures.load(%{"jamf" => leaf("x", "is", "y")}) == :error
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
    test "depth/1 and leaf_count/1 on an empty tree" do
      assert Postures.depth(%Postures{}) == 0
      assert Postures.leaf_count(%Postures{}) == 0
      assert Postures.max_depth() == 10
      assert Postures.max_leaves() == 100
    end

    test "depth/1 is the deepest provider" do
      map = %{
        "intune" => %{"and" => [leaf("compliance_state", "is", "x"), %{"or" => [leaf("notes", "exists")]}]},
        "iru" => leaf("mdm_enabled", "is", true)
      }

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
