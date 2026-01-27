defmodule PortalWeb.FormatTest do
  use ExUnit.Case, async: true

  alias PortalWeb.Format

  describe "short_date/1" do
    test "formats a date with single-digit month and day" do
      assert Format.short_date(~D[2026-01-05]) == "1/5/26"
    end

    test "formats a date with double-digit month and day" do
      assert Format.short_date(~D[2026-12-25]) == "12/25/26"
    end

    test "zero-pads the two-digit year" do
      assert Format.short_date(~D[2000-06-15]) == "6/15/00"
      assert Format.short_date(~D[2009-03-01]) == "3/1/09"
    end

    test "works with a DateTime" do
      dt = ~U[2026-07-04 14:30:00Z]
      assert Format.short_date(dt) == "7/4/26"
    end

    test "works with a NaiveDateTime" do
      ndt = ~N[2025-11-30 08:00:00]
      assert Format.short_date(ndt) == "11/30/25"
    end
  end

  describe "short_datetime/1" do
    test "formats midnight as 12:00 AM" do
      assert Format.short_datetime(~U[2026-01-27 00:00:00Z]) == "1/27/26, 12:00 AM"
    end

    test "formats noon as 12:00 PM" do
      assert Format.short_datetime(~U[2026-01-27 12:00:00Z]) == "1/27/26, 12:00 PM"
    end

    test "formats morning hours without zero-padding the hour" do
      assert Format.short_datetime(~U[2026-03-15 09:05:00Z]) == "3/15/26, 9:05 AM"
    end

    test "formats 1 AM" do
      assert Format.short_datetime(~U[2026-01-01 01:30:00Z]) == "1/1/26, 1:30 AM"
    end

    test "formats 11 AM" do
      assert Format.short_datetime(~U[2026-06-10 11:59:00Z]) == "6/10/26, 11:59 AM"
    end

    test "formats 1 PM (13:00)" do
      assert Format.short_datetime(~U[2026-01-27 13:00:00Z]) == "1/27/26, 1:00 PM"
    end

    test "formats 11 PM (23:00)" do
      assert Format.short_datetime(~U[2026-08-20 23:45:00Z]) == "8/20/26, 11:45 PM"
    end

    test "zero-pads minutes" do
      assert Format.short_datetime(~U[2026-01-27 15:03:00Z]) == "1/27/26, 3:03 PM"
    end

    test "zero-pads the two-digit year" do
      assert Format.short_datetime(~U[2000-01-01 00:00:00Z]) == "1/1/00, 12:00 AM"
    end

    test "works with a NaiveDateTime" do
      ndt = ~N[2026-12-31 23:59:00]
      assert Format.short_datetime(ndt) == "12/31/26, 11:59 PM"
    end
  end

  describe "relative_datetime/2" do
    defp base_time, do: ~U[2026-01-27 12:00:00Z]

    test "returns \"now\" for less than 2 seconds difference" do
      assert Format.relative_datetime(~U[2026-01-27 12:00:00Z], base_time()) == "now"
      assert Format.relative_datetime(~U[2026-01-27 12:00:01Z], base_time()) == "now"
      assert Format.relative_datetime(~U[2026-01-27 11:59:59Z], base_time()) == "now"
    end

    # Past (ago)

    test "returns seconds ago" do
      assert Format.relative_datetime(~U[2026-01-27 11:59:50Z], base_time()) == "10 seconds ago"
    end

    test "returns singular second ago" do
      # 2 seconds is the minimum non-"now" value
      assert Format.relative_datetime(~U[2026-01-27 11:59:58Z], base_time()) == "2 seconds ago"
    end

    test "returns minutes ago" do
      assert Format.relative_datetime(~U[2026-01-27 11:55:00Z], base_time()) == "5 minutes ago"
    end

    test "returns singular minute ago" do
      assert Format.relative_datetime(~U[2026-01-27 11:59:00Z], base_time()) == "1 minute ago"
    end

    test "returns hours ago" do
      assert Format.relative_datetime(~U[2026-01-27 09:00:00Z], base_time()) == "3 hours ago"
    end

    test "returns singular hour ago" do
      assert Format.relative_datetime(~U[2026-01-27 11:00:00Z], base_time()) == "1 hour ago"
    end

    test "returns days ago" do
      assert Format.relative_datetime(~U[2026-01-24 12:00:00Z], base_time()) == "3 days ago"
    end

    test "returns singular day ago" do
      assert Format.relative_datetime(~U[2026-01-26 12:00:00Z], base_time()) == "1 day ago"
    end

    test "returns weeks ago" do
      assert Format.relative_datetime(~U[2026-01-13 12:00:00Z], base_time()) == "2 weeks ago"
    end

    test "returns singular week ago" do
      assert Format.relative_datetime(~U[2026-01-20 12:00:00Z], base_time()) == "1 week ago"
    end

    test "returns months ago" do
      assert Format.relative_datetime(~U[2025-11-27 12:00:00Z], base_time()) == "2 months ago"
    end

    test "returns singular month ago" do
      assert Format.relative_datetime(~U[2025-12-28 12:00:00Z], base_time()) == "1 month ago"
    end

    test "returns years ago" do
      assert Format.relative_datetime(~U[2024-01-27 12:00:00Z], base_time()) == "2 years ago"
    end

    test "returns singular year ago" do
      assert Format.relative_datetime(~U[2025-01-27 12:00:00Z], base_time()) == "1 year ago"
    end

    # Future (in)

    test "returns seconds in the future" do
      assert Format.relative_datetime(~U[2026-01-27 12:00:30Z], base_time()) == "in 30 seconds"
    end

    test "returns minutes in the future" do
      assert Format.relative_datetime(~U[2026-01-27 12:10:00Z], base_time()) == "in 10 minutes"
    end

    test "returns hours in the future" do
      assert Format.relative_datetime(~U[2026-01-27 14:00:00Z], base_time()) == "in 2 hours"
    end

    test "returns days in the future" do
      assert Format.relative_datetime(~U[2026-01-30 12:00:00Z], base_time()) == "in 3 days"
    end

    test "returns weeks in the future" do
      assert Format.relative_datetime(~U[2026-02-10 12:00:00Z], base_time()) == "in 2 weeks"
    end

    test "returns months in the future" do
      assert Format.relative_datetime(~U[2026-04-27 12:00:00Z], base_time()) == "in 3 months"
    end

    test "returns years in the future" do
      assert Format.relative_datetime(~U[2031-01-27 12:00:00Z], base_time()) == "in 5 years"
    end

    # Boundary transitions

    test "59 seconds is still seconds" do
      assert Format.relative_datetime(~U[2026-01-27 11:59:01Z], base_time()) == "59 seconds ago"
    end

    test "60 seconds becomes 1 minute" do
      assert Format.relative_datetime(~U[2026-01-27 11:59:00Z], base_time()) == "1 minute ago"
    end

    test "59 minutes is still minutes" do
      assert Format.relative_datetime(~U[2026-01-27 11:01:00Z], base_time()) == "59 minutes ago"
    end

    test "60 minutes becomes 1 hour" do
      assert Format.relative_datetime(~U[2026-01-27 11:00:00Z], base_time()) == "1 hour ago"
    end

    test "23 hours is still hours" do
      assert Format.relative_datetime(~U[2026-01-26 13:00:00Z], base_time()) == "23 hours ago"
    end

    test "24 hours becomes 1 day" do
      assert Format.relative_datetime(~U[2026-01-26 12:00:00Z], base_time()) == "1 day ago"
    end

    test "6 days is still days" do
      assert Format.relative_datetime(~U[2026-01-21 12:00:00Z], base_time()) == "6 days ago"
    end

    test "7 days becomes 1 week" do
      assert Format.relative_datetime(~U[2026-01-20 12:00:00Z], base_time()) == "1 week ago"
    end
  end

  describe "cardinal_pluralize/2" do
    test "returns :one option when number is 1" do
      assert Format.cardinal_pluralize(1, %{one: "item", other: "items"}) == "item"
    end

    test "returns :other option when number is 0" do
      assert Format.cardinal_pluralize(0, %{other: "items"}) == "items"
    end

    test "returns :other option when number is greater than 1" do
      assert Format.cardinal_pluralize(5, %{one: "item", other: "items"}) == "items"
    end

    test "falls back to :other when :one is not provided and number is 1" do
      assert Format.cardinal_pluralize(1, %{other: "items"}) == "items"
    end

    test "returns nil when :other is not provided and number is not 1" do
      assert Format.cardinal_pluralize(2, %{one: "item"}) == nil
    end
  end
end
