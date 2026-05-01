defmodule Portal.Policies.ConditionTest do
  use Portal.DataCase, async: true

  alias Portal.Policies.Condition

  defp changeset(attrs) do
    Condition.changeset(%Condition{}, attrs, 0)
  end

  describe "changeset/3 defaults" do
    test "applies default property and operator when attrs are empty" do
      cs = changeset(%{})
      assert cs.changes[:property] == :remote_ip_location_region
      assert cs.changes[:operator] == :is_in
    end

    test "does not override provided property and operator" do
      cs = changeset(%{property: :remote_ip, operator: :is_in_cidr, values: ["10.0.0.0/8"]})
      assert Ecto.Changeset.get_field(cs, :property) == :remote_ip
      assert Ecto.Changeset.get_field(cs, :operator) == :is_in_cidr
    end
  end

  describe "changeset/3 with remote_ip_location_region" do
    test "valid with is_in and country codes" do
      cs = changeset(%{property: :remote_ip_location_region, operator: :is_in, values: ["US", "CA"]})
      assert cs.valid?
    end

    test "valid with is_not_in and country codes" do
      cs =
        changeset(%{property: :remote_ip_location_region, operator: :is_not_in, values: ["GB"]})

      assert cs.valid?
    end

    test "invalid operator returns error" do
      cs = changeset(%{property: :remote_ip_location_region, operator: :is, values: ["US"]})
      assert cs.errors[:operator]
    end

    test "invalid country code returns values error" do
      cs =
        changeset(%{
          property: :remote_ip_location_region,
          operator: :is_in,
          values: ["NOTACODE"]
        })

      assert cs.errors[:values]
    end
  end

  describe "changeset/3 with remote_ip" do
    test "valid with is_in_cidr and CIDR notation" do
      cs = changeset(%{property: :remote_ip, operator: :is_in_cidr, values: ["10.0.0.0/8"]})
      assert cs.valid?
    end

    test "valid with is_not_in_cidr" do
      cs =
        changeset(%{property: :remote_ip, operator: :is_not_in_cidr, values: ["192.168.0.0/24"]})

      assert cs.valid?
    end

    test "invalid operator returns error" do
      cs = changeset(%{property: :remote_ip, operator: :is_in, values: ["10.0.0.0/8"]})
      assert cs.errors[:operator]
    end

    test "malformed CIDR returns values error" do
      cs = changeset(%{property: :remote_ip, operator: :is_in_cidr, values: ["not-an-ip"]})
      assert cs.errors[:values]
    end
  end

  describe "changeset/3 with auth_provider_id" do
    test "valid with is_in and UUIDs" do
      uuid = Ecto.UUID.generate()
      cs = changeset(%{property: :auth_provider_id, operator: :is_in, values: [uuid]})
      assert cs.valid?
    end

    test "valid with is_not_in and UUIDs" do
      uuid = Ecto.UUID.generate()
      cs = changeset(%{property: :auth_provider_id, operator: :is_not_in, values: [uuid]})
      assert cs.valid?
    end

    test "invalid operator returns error" do
      uuid = Ecto.UUID.generate()
      cs = changeset(%{property: :auth_provider_id, operator: :is, values: [uuid]})
      assert cs.errors[:operator]
    end

    test "non-UUID value returns values error" do
      cs =
        changeset(%{property: :auth_provider_id, operator: :is_in, values: ["not-a-uuid"]})

      assert cs.errors[:values]
    end
  end

  describe "changeset/3 with current_utc_datetime" do
    test "valid with is_in_day_of_week_time_ranges and valid time range" do
      cs =
        changeset(%{
          property: :current_utc_datetime,
          operator: :is_in_day_of_week_time_ranges,
          values: ["M/09:00-17:00/UTC"]
        })

      assert cs.valid?
    end

    test "invalid operator returns error" do
      cs =
        changeset(%{
          property: :current_utc_datetime,
          operator: :is_in,
          values: ["M/09:00-17:00/UTC"]
        })

      assert cs.errors[:operator]
    end

    test "malformed time range returns values error" do
      cs =
        changeset(%{
          property: :current_utc_datetime,
          operator: :is_in_day_of_week_time_ranges,
          values: ["M/not-a-range/UTC"]
        })

      assert cs.errors[:values]
    end

    test "missing timezone returns values error" do
      cs =
        changeset(%{
          property: :current_utc_datetime,
          operator: :is_in_day_of_week_time_ranges,
          values: ["M/09:00-17:00"]
        })

      assert cs.errors[:values]
    end
  end

  describe "changeset/3 with client_verified" do
    test "valid with is and true" do
      cs = changeset(%{property: :client_verified, operator: :is, values: ["true"]})
      assert cs.valid?
    end

    test "valid with is and false" do
      cs = changeset(%{property: :client_verified, operator: :is, values: ["false"]})
      assert cs.valid?
    end

    test "invalid operator returns error" do
      cs = changeset(%{property: :client_verified, operator: :is_in, values: ["true"]})
      assert cs.errors[:operator]
    end

    test "more than one value returns length error" do
      cs =
        changeset(%{property: :client_verified, operator: :is, values: ["true", "false"]})

      assert cs.errors[:values]
    end

    test "empty values list returns length error" do
      cs = changeset(%{property: :client_verified, operator: :is, values: []})
      assert cs.errors[:values]
    end
  end
end
