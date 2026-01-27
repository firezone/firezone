defmodule PortalWeb.Format do
  @moduledoc """
  Lightweight date, datetime, and number formatting helpers for English locale.
  Replaces ex_cldr for our English-only use case.
  """

  @doc """
  Formats a date in US short format: "1/27/26"
  """
  def short_date(%{year: y, month: m, day: d}) do
    year_2d = y |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{m}/#{d}/#{year_2d}"
  end

  @doc """
  Formats a datetime in US short format: "1/27/26, 3:45 PM"
  """
  def short_datetime(%{year: y, month: m, day: d, hour: h, minute: min}) do
    year_2d = y |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    {hour_12, period} = to_12_hour(h)
    minute_str = min |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{m}/#{d}/#{year_2d}, #{hour_12}:#{minute_str} #{period}"
  end

  @doc """
  Returns a relative time string like "2 hours ago" or "in 3 days".
  """
  def relative_datetime(datetime, relative_to \\ nil) do
    relative_to = relative_to || DateTime.utc_now()
    diff = DateTime.diff(datetime, relative_to, :second)
    abs_diff = abs(diff)

    {value, unit} = pick_unit(abs_diff)
    unit_str = if value == 1, do: unit, else: "#{unit}s"

    cond do
      abs_diff < 2 -> "now"
      diff < 0 -> "#{value} #{unit_str} ago"
      true -> "in #{value} #{unit_str}"
    end
  end

  @doc """
  Returns the appropriate plural form for a cardinal number in English.
  Accepts a map of options with keys like :one, :other, :zero, etc.
  """
  def cardinal_pluralize(number, opts) do
    if number == 1 do
      opts[:one] || opts[:other]
    else
      opts[:other]
    end
  end

  defp pick_unit(seconds) when seconds < 60, do: {seconds, "second"}
  defp pick_unit(seconds) when seconds < 3_600, do: {div(seconds, 60), "minute"}
  defp pick_unit(seconds) when seconds < 86_400, do: {div(seconds, 3_600), "hour"}
  defp pick_unit(seconds) when seconds < 604_800, do: {div(seconds, 86_400), "day"}
  defp pick_unit(seconds) when seconds < 2_592_000, do: {div(seconds, 604_800), "week"}
  defp pick_unit(seconds) when seconds < 31_536_000, do: {div(seconds, 2_592_000), "month"}
  defp pick_unit(seconds), do: {div(seconds, 31_536_000), "year"}

  defp to_12_hour(0), do: {12, "AM"}
  defp to_12_hour(12), do: {12, "PM"}
  defp to_12_hour(h) when h > 0 and h < 12, do: {h, "AM"}
  defp to_12_hour(h) when h > 12 and h < 24, do: {h - 12, "PM"}
end
