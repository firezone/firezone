defmodule Domain.Policies.EvaluatorTest do
  use Domain.DataCase, async: true
  import Domain.Policies.Evaluator

  # describe "ensure_conforms/2" do
  #  test "returns ok when there are no conditions" do
  #    client = %Domain.Client{}
  #    assert ensure_conforms([], client) == {:ok, nil}
  #  end

  #  test "returns ok when all conditions are met" do
  #    client = %Domain.Client{
  #      last_seen_remote_ip_location_region: "US",
  #      last_seen_remote_ip: %Postgrex.INET{address: {192, 168, 0, 1}}
  #    }

  #    conditions = [
  #      %Domain.Policies.Condition{
  #        property: :remote_ip_location_region,
  #        operator: :is_in,
  #        values: ["US"]
  #      },
  #      %Domain.Policies.Condition{
  #        property: :remote_ip,
  #        operator: :is_in_cidr,
  #        values: ["192.168.0.1/24"]
  #      }
  #    ]

  #    assert ensure_conforms(conditions, client) == {:ok, nil}
  #  end

  #  test "returns error when all conditions are not met" do
  #    client = %Domain.Client{
  #      last_seen_remote_ip_location_region: "US",
  #      last_seen_remote_ip: %Postgrex.INET{address: {192, 168, 0, 1}}
  #    }

  #    conditions = [
  #      %Domain.Policies.Condition{
  #        property: :remote_ip_location_region,
  #        operator: :is_in,
  #        values: ["CN"]
  #      },
  #      %Domain.Policies.Condition{
  #        property: :remote_ip,
  #        operator: :is_in_cidr,
  #        values: ["10.10.0.1/24"]
  #      }
  #    ]

  #    assert ensure_conforms(conditions, client) ==
  #             {:error, [:remote_ip_location_region, :remote_ip]}
  #  end

  #  test "returns error when one of the conditions is not met" do
  #    client = %Domain.Client{
  #      last_seen_remote_ip_location_region: "US",
  #      last_seen_remote_ip: %Postgrex.INET{address: {192, 168, 0, 1}}
  #    }

  #    conditions = [
  #      %Domain.Policies.Condition{
  #        property: :remote_ip_location_region,
  #        operator: :is_in,
  #        values: ["CN"]
  #      },
  #      %Domain.Policies.Condition{
  #        property: :remote_ip,
  #        operator: :is_in_cidr,
  #        values: ["192.168.0.1/24"]
  #      }
  #    ]

  #    assert ensure_conforms(conditions, client) ==
  #             {:error, [:remote_ip_location_region]}
  #  end
  # end

  # describe "fetch_conformation_expiration/2" do
  #  test "when client last seen remote ip location region is in or not in the values" do
  #    condition = %Domain.Policies.Condition{
  #      property: :remote_ip_location_region,
  #      values: ["US"]
  #    }

  #    client = %Domain.Client{
  #      last_seen_remote_ip_location_region: "US"
  #    }

  #    assert fetch_conformation_expiration(%{condition | operator: :is_in}, client) == {:ok, nil}
  #    assert fetch_conformation_expiration(%{condition | operator: :is_not_in}, client) == :error

  #    client = %Domain.Client{
  #      last_seen_remote_ip_location_region: "CA"
  #    }

  #    assert fetch_conformation_expiration(%{condition | operator: :is_in}, client) == :error

  #    assert fetch_conformation_expiration(%{condition | operator: :is_not_in}, client) ==
  #             {:ok, nil}
  #  end

  #  test "when client last seen remote ip is in or not in the CIDR values" do
  #    condition = %Domain.Policies.Condition{
  #      property: :remote_ip,
  #      values: ["192.168.0.1/24"]
  #    }

  #    client = %Domain.Client{
  #      last_seen_remote_ip: %Postgrex.INET{address: {192, 168, 0, 1}}
  #    }

  #    assert fetch_conformation_expiration(%{condition | operator: :is_in_cidr}, client) ==
  #             {:ok, nil}

  #    assert fetch_conformation_expiration(%{condition | operator: :is_not_in_cidr}, client) ==
  #             :error

  #    client = %Domain.Client{
  #      last_seen_remote_ip: %Postgrex.INET{address: {10, 168, 0, 1}}
  #    }

  #    assert fetch_conformation_expiration(%{condition | operator: :is_in_cidr}, client) == :error

  #    assert fetch_conformation_expiration(%{condition | operator: :is_not_in_cidr}, client) ==
  #             {:ok, nil}
  #  end

  #  test "when client last seen remote ip is in or not in the IP values" do
  #    condition = %Domain.Policies.Condition{
  #      property: :remote_ip,
  #      values: ["192.168.0.1", "2001:0000:130F:0000:0000:09C0:876A:130B"]
  #    }

  #    client = %Domain.Client{
  #      last_seen_remote_ip: %Postgrex.INET{address: {192, 168, 0, 1}}
  #    }

  #    assert fetch_conformation_expiration(%{condition | operator: :is_in_cidr}, client) ==
  #             {:ok, nil}

  #    assert fetch_conformation_expiration(%{condition | operator: :is_not_in_cidr}, client) ==
  #             :error

  #    client = %Domain.Client{
  #      last_seen_remote_ip: %Postgrex.INET{address: {10, 168, 0, 1}}
  #    }

  #    assert fetch_conformation_expiration(%{condition | operator: :is_in_cidr}, client) == :error

  #    assert fetch_conformation_expiration(%{condition | operator: :is_not_in_cidr}, client) ==
  #             {:ok, nil}
  #  end

  #  # test "when client identity provider id is in or not in the values" do
  #  #  condition = %Domain.Policies.Condition{
  #  #    property: :provider_id,
  #  #    values: ["00000000-0000-0000-0000-000000000000"]
  #  #  }

  #  #  client = %Domain.Client{
  #  #    identity: %Domain.ExternalIdentity{
  #  #      provider_id: "00000000-0000-0000-0000-000000000000"
  #  #    }
  #  #  }

  #  #  assert fetch_conformation_expiration(%{condition | operator: :is_in}, client) == {:ok, nil}
  #  #  assert fetch_conformation_expiration(%{condition | operator: :is_not_in}, client) == :error

  #  #  client = %Domain.Client{
  #  #    identity: %Domain.ExternalIdentity{
  #  #      provider_id: "11111111-1111-1111-1111-111111111111"
  #  #    }
  #  #  }

  #  #  assert fetch_conformation_expiration(%{condition | operator: :is_in}, client) == :error

  #  #  assert fetch_conformation_expiration(%{condition | operator: :is_not_in}, client) ==
  #  #           {:ok, nil}
  #  # end

  #  test "when client verified is required" do
  #    verified_client = %Domain.Client{verified_at: DateTime.utc_now()}
  #    not_verified_client = %Domain.Client{verified_at: nil}

  #    condition = %Domain.Policies.Condition{
  #      property: :client_verified,
  #      operator: :is,
  #      values: ["true"]
  #    }

  #    assert fetch_conformation_expiration(condition, verified_client) == {:ok, nil}
  #    assert fetch_conformation_expiration(condition, not_verified_client) == :error

  #    condition = %Domain.Policies.Condition{
  #      property: :client_verified,
  #      operator: :is,
  #      values: ["false"]
  #    }

  #    assert fetch_conformation_expiration(condition, verified_client) == {:ok, nil}
  #    assert fetch_conformation_expiration(condition, not_verified_client) == {:ok, nil}

  #    condition = %Domain.Policies.Condition{
  #      property: :client_verified,
  #      operator: :is,
  #      values: nil
  #    }

  #    assert fetch_conformation_expiration(condition, verified_client) == {:ok, nil}
  #    assert fetch_conformation_expiration(condition, not_verified_client) == {:ok, nil}
  #  end

  #  test "when client current UTC datetime is in the day of the week time ranges" do
  #    # this is deeply tested separately in find_day_of_the_week_time_range/2
  #    condition = %Domain.Policies.Condition{
  #      property: :current_utc_datetime,
  #      values: []
  #    }

  #    client = %Domain.Client{}

  #    assert fetch_conformation_expiration(
  #             %{condition | operator: :is_in_day_of_week_time_ranges},
  #             client
  #           ) == :error
  #  end
  # end

  describe "find_day_of_the_week_time_range/2" do
    test "returns true when datetime is in the day of the week time ranges" do
      # Friday
      datetime = ~U[2021-01-01 10:00:00Z]

      # Exact match
      dow_time_ranges = ["F/10:00:00-10:00:00/UTC"]

      assert DateTime.compare(
               find_day_of_the_week_time_range(dow_time_ranges, datetime),
               ~U[2021-01-01 10:00:00Z]
             ) == :eq

      # Range start match
      dow_time_ranges = ["F/10:00:00-11:00:00,20:00-22:00/UTC"]

      assert DateTime.compare(
               find_day_of_the_week_time_range(dow_time_ranges, datetime),
               ~U[2021-01-01 11:00:00Z]
             ) == :eq

      # Range end match
      dow_time_ranges = ["F/09:00:00-10:00:00,11-22/UTC"]

      assert DateTime.compare(
               find_day_of_the_week_time_range(dow_time_ranges, datetime),
               ~U[2021-01-01 10:00:00Z]
             ) == :eq

      # Entire day match
      dow_time_ranges = ["F/true/UTC"]

      assert DateTime.compare(
               find_day_of_the_week_time_range(dow_time_ranges, datetime),
               ~U[2021-01-01 23:59:59Z]
             ) == :eq

      # Finds greatest expiration time
      dow_time_ranges = ["F/09:00:00-11:00:00,11-15,14-22/UTC"]

      assert DateTime.compare(
               find_day_of_the_week_time_range(dow_time_ranges, datetime),
               ~U[2021-01-01 22:00:00Z]
             ) == :eq
    end

    test "returns false when datetime is not in the day of the week time ranges" do
      # Friday
      datetime = ~U[2021-01-01 10:00:00Z]

      dow_time_ranges = ["F/09:00:00-09:59:59/UTC"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil

      dow_time_ranges = ["F/10:00:01-11:00:00/UTC"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil

      dow_time_ranges = ["M/09:00:00-11:00:00/UTC"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil

      dow_time_ranges = ["U/true/UTC"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil
    end

    test "handles different timezones" do
      # 01:00 Friday in UTC, 07:00 Thursday in US/Pacific (UTC-8)
      datetime = ~U[2021-01-01 01:00:00Z]

      # Thursday in US/Pacific ends at 07:59:59 UTC
      dow_time_ranges = ["R/true/US/Pacific"]

      assert DateTime.compare(
               find_day_of_the_week_time_range(dow_time_ranges, datetime),
               ~U[2021-01-01 07:59:59Z]
             ) == :eq

      # Friday in UTC
      dow_time_ranges = ["F/true/UTC"]

      assert DateTime.compare(
               find_day_of_the_week_time_range(dow_time_ranges, datetime),
               ~U[2021-01-01 23:59:59Z]
             ) == :eq

      # 19:00 Thursday in US/Pacific (UTC-8) = 03:00 Friday in UTC
      dow_time_ranges = ["R/15:00:00-19:00:00/US/Pacific"]

      assert DateTime.compare(
               find_day_of_the_week_time_range(dow_time_ranges, datetime),
               ~U[2021-01-01 03:00:00Z]
             ) == :eq

      # given datetime is 07:00 Thursday in US/Pacific (UTC-8), so Friday in UTC should not match
      dow_time_ranges = ["R/00:00:00-02:00:00/US/Pacific"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil

      # Poland timezone is UTC+1, given datetime in UTC is 02:00 Friday in Poland
      dow_time_ranges = ["F/02:00:00-04:00:00/Poland"]

      assert DateTime.compare(
               find_day_of_the_week_time_range(dow_time_ranges, datetime),
               ~U[2021-01-01 03:00:00Z]
             ) == :eq
    end

    test "returns false when ranges are invalid" do
      datetime = ~U[2021-01-01 10:00:00Z]

      dow_time_ranges = ["F/10:00:00-09:59:59/UTC"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil

      dow_time_ranges = ["F/11:00:00-12:00:00-/US/Pacific"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil

      dow_time_ranges = ["F/false/UTC"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil

      dow_time_ranges = ["F/10-11"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil

      dow_time_ranges = ["F/10-11/"]
      assert find_day_of_the_week_time_range(dow_time_ranges, datetime) == nil
    end
  end

  describe "merge_joint_time_ranges/1" do
    test "does nothing on empty time ranges" do
      time_ranges = []
      assert merge_joint_time_ranges(time_ranges) == time_ranges
    end

    test "does nothing on single time range" do
      time_ranges = [{~T[10:00:00], ~T[11:00:00], "UTC"}]
      assert merge_joint_time_ranges(time_ranges) == time_ranges
    end

    test "does not merge overlapping time ranges that do not overlap" do
      time_ranges = [
        {~T[10:00:00], ~T[11:00:00], "UTC"},
        {~T[11:00:01], ~T[12:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == time_ranges

      time_ranges = [
        {~T[09:00:00], ~T[10:00:00], "UTC"},
        {~T[11:00:00], ~T[12:00:00], "UTC"},
        {~T[10:00:01], ~T[10:00:02], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == time_ranges
    end

    test "does not merge overlapping time ranges that have different timezones" do
      time_ranges = [
        {~T[10:00:00], ~T[11:00:00], "UTC"},
        {~T[10:30:00], ~T[12:00:00], "PDT"}
      ]

      assert merge_joint_time_ranges(time_ranges) == time_ranges
    end

    test "merges overlapping time ranges" do
      time_ranges = [
        {~T[10:00:00], ~T[11:00:00], "UTC"},
        {~T[10:30:00], ~T[12:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == [
               {~T[10:00:00], ~T[12:00:00], "UTC"}
             ]

      time_ranges = [
        {~T[10:00:00], ~T[11:00:00], "UTC"},
        {~T[11:00:00], ~T[12:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == [
               {~T[10:00:00], ~T[12:00:00], "UTC"}
             ]

      time_ranges = [
        {~T[10:00:00], ~T[11:00:00], "UTC"},
        {~T[09:00:00], ~T[10:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == [
               {~T[09:00:00], ~T[11:00:00], "UTC"}
             ]

      time_ranges = [
        {~T[10:00:00], ~T[11:00:00], "UTC"},
        {~T[10:00:00], ~T[12:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == [
               {~T[10:00:00], ~T[12:00:00], "UTC"}
             ]

      time_ranges = [
        {~T[10:00:00], ~T[11:00:00], "UTC"},
        {~T[09:00:00], ~T[12:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == [
               {~T[09:00:00], ~T[12:00:00], "UTC"}
             ]

      time_ranges = [
        {~T[09:00:00], ~T[12:00:00], "UTC"},
        {~T[10:00:00], ~T[11:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == [
               {~T[09:00:00], ~T[12:00:00], "UTC"}
             ]
    end

    test "merges multiple overlapping time ranges" do
      time_ranges = [
        {~T[09:00:00], ~T[10:00:00], "UTC"},
        {~T[11:00:00], ~T[12:00:00], "UTC"},
        {~T[10:00:00], ~T[11:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == [
               {~T[09:00:00], ~T[12:00:00], "UTC"}
             ]

      time_ranges = [
        {~T[09:00:00], ~T[12:00:00], "UTC"},
        {~T[11:00:00], ~T[12:00:00], "UTC"},
        {~T[10:00:00], ~T[11:00:00], "UTC"},
        {~T[09:00:00], ~T[10:00:00], "UTC"},
        {~T[01:00:00], ~T[10:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == [
               {~T[01:00:00], ~T[12:00:00], "UTC"}
             ]
    end

    test "merges two sets of overlapping time ranges" do
      time_ranges = [
        {~T[09:00:00], ~T[12:00:00], "UTC"},
        {~T[11:00:00], ~T[13:00:00], "UTC"},
        {~T[10:00:00], ~T[11:00:00], "UTC"},
        {~T[02:00:00], ~T[05:00:00], "UTC"},
        {~T[01:00:00], ~T[08:00:00], "UTC"}
      ]

      assert merge_joint_time_ranges(time_ranges) == [
               {~T[09:00:00], ~T[13:00:00], "UTC"},
               {~T[01:00:00], ~T[08:00:00], "UTC"}
             ]
    end
  end

  describe "parse_days_of_week_time_ranges/1" do
    test "parses list of days of the week time ranges" do
      assert parse_days_of_week_time_ranges(["M/true/UTC"]) ==
               {:ok, %{"M" => [{~T[00:00:00], ~T[23:59:59], "UTC"}]}}

      assert parse_days_of_week_time_ranges([
               "M/true/UTC",
               "W/19:00:00-22:00:00,22-23/US/Pacific"
             ]) ==
               {:ok,
                %{
                  "M" => [
                    {~T[00:00:00], ~T[23:59:59], "UTC"}
                  ],
                  "W" => [
                    {~T[19:00:00], ~T[22:00:00], "US/Pacific"},
                    {~T[22:00:00], ~T[23:00:00], "US/Pacific"}
                  ]
                }}
    end

    test "merges list of days of the week time ranges" do
      assert parse_days_of_week_time_ranges([
               "M/true,10:00:00-11:00:00/UTC",
               "W/19:00:00-22:00:00/US/Pacific"
             ]) ==
               {:ok,
                %{
                  "M" => [
                    {~T[00:00:00], ~T[23:59:59], "UTC"},
                    {~T[10:00:00], ~T[11:00:00], "UTC"}
                  ],
                  "W" => [
                    {~T[19:00:00], ~T[22:00:00], "US/Pacific"}
                  ]
                }}

      assert parse_days_of_week_time_ranges([
               "M/true/UTC",
               "W/19:00:00-22:00:00/UTC",
               "M/10:00:00-11:00:00/UTC"
             ]) ==
               {:ok,
                %{
                  "M" => [
                    {~T[00:00:00], ~T[23:59:59], "UTC"},
                    {~T[10:00:00], ~T[11:00:00], "UTC"}
                  ],
                  "W" => [
                    {~T[19:00:00], ~T[22:00:00], "UTC"}
                  ]
                }}

      assert parse_days_of_week_time_ranges([
               "M/22:00:00-22:30/UTC",
               "M/19-22:00:00/UTC",
               "M/true/UTC"
             ]) ==
               {:ok,
                %{
                  "M" => [
                    {~T[22:00:00], ~T[22:30:00], "UTC"},
                    {~T[19:00:00], ~T[22:00:00], "UTC"},
                    {~T[00:00:00], ~T[23:59:59], "UTC"}
                  ]
                }}

      assert parse_days_of_week_time_ranges([
               "M/09:00:00-10:00:00/UTC",
               "W/19:00:00-22:00:00/UTC",
               "M/10:00:00-11:00:00/UTC"
             ]) ==
               {:ok,
                %{
                  "M" => [
                    {~T[09:00:00], ~T[10:00:00], "UTC"},
                    {~T[10:00:00], ~T[11:00:00], "UTC"}
                  ],
                  "W" => [
                    {~T[19:00:00], ~T[22:00:00], "UTC"}
                  ]
                }}
    end

    test "returns error on invalid timezone" do
      assert parse_days_of_week_time_ranges(["M/true"]) ==
               {:error, "timezone is required"}

      assert parse_days_of_week_time_ranges(["M/true/invalid"]) ==
               {:error, "invalid timezone"}
    end
  end

  describe "parse_day_of_week_time_ranges/1" do
    test "parses 7 days of the week" do
      for day <- ~w[M T W R F S U] do
        assert {:ok,
                {^day,
                 [
                   {~T[00:00:00], ~T[23:59:59], "US/Pacific"}
                 ]}} = parse_day_of_week_time_ranges("#{day}/true/US/Pacific")
      end
    end

    test "parses day of week time ranges" do
      assert parse_day_of_week_time_ranges("M/08:00:00-17:00:00,22:00:00-23:59:59/America/Merida") ==
               {:ok,
                {"M",
                 [
                   {~T[08:00:00], ~T[17:00:00], "America/Merida"},
                   {~T[22:00:00], ~T[23:59:59], "America/Merida"}
                 ]}}

      assert parse_day_of_week_time_ranges("U/08:00:00-17:00:00/UTC") ==
               {:ok, {"U", [{~T[08:00:00], ~T[17:00:00], "UTC"}]}}

      assert parse_day_of_week_time_ranges("U/08:00-17:00:00/US/Pacific") ==
               {:ok, {"U", [{~T[08:00:00], ~T[17:00:00], "US/Pacific"}]}}
    end

    test "returns error when invalid day of week is provided" do
      assert parse_day_of_week_time_ranges("X/08:00:00-17:00:00/UTC") ==
               {:error, "invalid day of the week, must be one of M, T, W, R, F, S, U"}
    end

    test "returns error when invalid time range is provided" do
      assert parse_day_of_week_time_ranges("M/08:00:00-17:00:00-/UTC") ==
               {:error, "invalid time range: 08:00:00-17:00:00-"}
    end

    test "returns error when invalid time is provided" do
      assert parse_day_of_week_time_ranges("M/25-17:00:00/UTC") ==
               {:error, "invalid time range: 25-17:00:00"}

      assert parse_day_of_week_time_ranges("M/08:00:00-25/UTC") ==
               {:error, "invalid time range: 08:00:00-25"}
    end

    test "returns error when start of the time range is greater than the end of it" do
      assert {:error, "start of the time range must be less than or equal to the end of it"} =
               parse_day_of_week_time_ranges("M/17:00:00-08:00:00/UTC")
    end
  end

  describe "parse_time_ranges/1" do
    test "parses time ranges" do
      assert parse_time_ranges("true") ==
               {:ok, [{~T[00:00:00], ~T[23:59:59]}]}

      assert parse_time_ranges("08:00:00-17:00:00") ==
               {:ok, [{~T[08:00:00], ~T[17:00:00]}]}

      assert parse_time_ranges("08:00-17:00:00") ==
               {:ok, [{~T[08:00:00], ~T[17:00:00]}]}

      assert parse_time_ranges("08:00:00-17:00") ==
               {:ok, [{~T[08:00:00], ~T[17:00:00]}]}

      assert parse_time_ranges("08-17:00:00") ==
               {:ok, [{~T[08:00:00], ~T[17:00:00]}]}

      assert parse_time_ranges("08:00:00-17") ==
               {:ok, [{~T[08:00:00], ~T[17:00:00]}]}

      assert parse_time_ranges("08:00:00-17:00:00,09:00:00-10:00:00") ==
               {:ok, [{~T[08:00:00], ~T[17:00:00]}, {~T[09:00:00], ~T[10:00:00]}]}
    end

    test "returns error when invalid time range is provided" do
      assert parse_time_ranges("08:00:00-17:00:00-") ==
               {:error, "invalid time range: 08:00:00-17:00:00-"}
    end

    test "returns error when invalid time is provided" do
      assert parse_time_ranges("25:00:00-17:00:00") ==
               {:error, "invalid time range: 25:00:00-17:00:00"}

      assert parse_time_ranges("08:00:00-25:00:00") ==
               {:error, "invalid time range: 08:00:00-25:00:00"}

      assert parse_time_ranges("25-17:00:00") ==
               {:error, "invalid time range: 25-17:00:00"}

      assert parse_time_ranges("08:00:00-25") ==
               {:error, "invalid time range: 08:00:00-25"}
    end

    test "returns error when start of the time range is greater than the end of it" do
      assert {:error, "start of the time range must be less than or equal to the end of it"} =
               parse_time_ranges("17:00:00-08:00:00")
    end
  end

  describe "parse_time_range/1" do
    test "parses time range" do
      assert parse_time_range("08:00:00-17:00:00") ==
               {:ok, {~T[08:00:00], ~T[17:00:00]}}

      assert parse_time_range("08:00-17:00:00") ==
               {:ok, {~T[08:00:00], ~T[17:00:00]}}

      assert parse_time_range("08:00:00-17:00") ==
               {:ok, {~T[08:00:00], ~T[17:00:00]}}

      assert parse_time_range("true") ==
               {:ok, {~T[00:00:00], ~T[23:59:59]}}
    end

    test "returns error when invalid time range is provided" do
      assert parse_time_range("08:00:00-17:00:00-") ==
               {:error, "invalid time range: 08:00:00-17:00:00-"}
    end

    test "returns error when invalid time is provided" do
      assert parse_time_range("25-17:00:00") ==
               {:error, "invalid time range: 25-17:00:00"}

      assert parse_time_range("08:00:00-33") ==
               {:error, "invalid time range: 08:00:00-33"}
    end

    test "returns error when start of the time range is greater than the end of it" do
      assert {:error, "start of the time range must be less than or equal to the end of it"} =
               parse_time_range("17:00:00-08:00:00")
    end
  end
end
