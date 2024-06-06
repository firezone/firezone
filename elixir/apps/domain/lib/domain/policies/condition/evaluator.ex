defmodule Domain.Policies.Condition.Evaluator do
  alias Domain.Repo
  alias Domain.Clients
  alias Domain.Policies.Condition

  @days_of_week ~w[M T W R F S U]

  def ensure_conforms([], %Clients.Client{}) do
    :ok
  end

  def ensure_conforms(conditions, %Clients.Client{} = client) when is_list(conditions) do
    client = Repo.preload(client, :identity)

    conditions
    |> Enum.reduce([], fn condition, violated_properties ->
      cond do
        conforms?(condition, client) -> violated_properties
        condition.property in violated_properties -> violated_properties
        true -> [condition.property | violated_properties]
      end
    end)
    |> case do
      [] -> :ok
      violated_properties -> {:error, Enum.reverse(violated_properties)}
    end
  end

  def conforms?(
        %Condition{property: :remote_ip_location_region, operator: :is_in, values: values},
        %Clients.Client{} = client
      ) do
    client.last_seen_remote_ip_location_region in values
  end

  def conforms?(
        %Condition{property: :remote_ip_location_region, operator: :is_not_in, values: values},
        %Clients.Client{} = client
      ) do
    client.last_seen_remote_ip_location_region not in values
  end

  def conforms?(
        %Condition{property: :remote_ip, operator: :is_in_cidr, values: values},
        %Clients.Client{} = client
      ) do
    Enum.any?(values, fn cidr ->
      {:ok, cidr} = Domain.Types.CIDR.cast(cidr)
      Domain.Types.CIDR.contains?(cidr, client.last_seen_remote_ip)
    end)
  end

  def conforms?(
        %Condition{property: :remote_ip, operator: :is_not_in_cidr, values: values},
        %Clients.Client{} = client
      ) do
    Enum.all?(values, fn cidr ->
      {:ok, cidr} = Domain.Types.CIDR.cast(cidr)
      not Domain.Types.CIDR.contains?(cidr, client.last_seen_remote_ip)
    end)
  end

  def conforms?(
        %Condition{property: :provider_id, operator: :is_in, values: values},
        %Clients.Client{} = client
      ) do
    client = Repo.preload(client, :identity)
    client.identity.provider_id in values
  end

  def conforms?(
        %Condition{property: :provider_id, operator: :is_not_in, values: values},
        %Clients.Client{} = client
      ) do
    client = Repo.preload(client, :identity)
    client.identity.provider_id not in values
  end

  def conforms?(
        %Condition{
          property: :current_utc_datetime,
          operator: :is_in_day_of_week_time_ranges,
          values: values
        },
        %Clients.Client{}
      ) do
    datetime_in_day_of_the_week_time_ranges?(DateTime.utc_now(), values)
  end

  def datetime_in_day_of_the_week_time_ranges?(datetime, dow_time_ranges) do
    dow_time_ranges
    |> parse_days_of_week_time_ranges()
    |> case do
      {:ok, dow_time_ranges} ->
        Enum.any?(dow_time_ranges, fn {day, time_ranges} ->
          datetime_in_time_ranges?(datetime, day, time_ranges)
        end)

      {:error, _reason} ->
        false
    end
  end

  defp datetime_in_time_ranges?(datetime, day_of_the_week, time_ranges) do
    Enum.any?(time_ranges, fn {start_time, end_time, timezone} ->
      {:ok, datetime} = DateTime.shift_zone(datetime, timezone, Tzdata.TimeZoneDatabase)
      date = DateTime.to_date(datetime)
      time = DateTime.to_time(datetime)

      if Enum.at(@days_of_week, Date.day_of_week(date) - 1) == day_of_the_week do
        Time.compare(start_time, time) != :gt and Time.compare(time, end_time) != :gt
      else
        false
      end
    end)
  end

  def parse_days_of_week_time_ranges(dows_time_ranges) do
    Enum.reduce_while(dows_time_ranges, {:ok, %{}}, fn dow_time_ranges, {:ok, acc} ->
      case parse_day_of_week_time_ranges(dow_time_ranges) do
        {:ok, {day, dow_time_ranges}} ->
          {_current_value, acc} =
            Map.get_and_update(acc, day, fn
              nil -> {nil, dow_time_ranges}
              current_value -> {current_value, current_value ++ dow_time_ranges}
            end)

          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def parse_day_of_week_time_ranges(dow_time_ranges) do
    case String.split(dow_time_ranges, "/", parts: 3) do
      [day, time_ranges, timezone] when day in @days_of_week ->
        with {:ok, time_ranges} <- parse_time_ranges(time_ranges, timezone) do
          {:ok, {day, time_ranges}}
        end

      [_day, _time_ranges] ->
        {:error, "timezone is required"}

      _ ->
        {:error, "invalid day of the week, must be one of #{Enum.join(@days_of_week, ", ")}"}
    end
  end

  def parse_time_ranges(time_ranges, timezone) do
    with true <- Tzdata.zone_exists?(timezone),
         {:ok, time_ranges} <- parse_time_ranges(time_ranges) do
      time_ranges =
        Enum.map(time_ranges, fn {start_time, end_time} ->
          {start_time, end_time, timezone}
        end)

      {:ok, time_ranges}
    else
      false ->
        {:error, "invalid timezone"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse_time_ranges(nil) do
    {:ok, []}
  end

  def parse_time_ranges(time_ranges) do
    String.split(time_ranges, ",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn time_range, {:ok, acc} ->
      time_range
      |> String.trim()
      |> parse_time_range()
      |> case do
        {:ok, time} ->
          {:cont, {:ok, [time | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, time_ranges} ->
        {:ok, Enum.reverse(time_ranges)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse_time_range("true") do
    {:ok, {~T[00:00:00], ~T[23:59:59]}}
  end

  def parse_time_range(time_range) do
    with [start_time, end_time] <- String.split(time_range, "-", parts: 2, trim: true),
         {:ok, start_time} <- parse_time(start_time),
         {:ok, end_time} <- parse_time(end_time),
         true <- Time.compare(start_time, end_time) != :gt do
      {:ok, {start_time, end_time}}
    else
      false ->
        {:error, "start of the time range must be less than or equal to the end of it"}

      _ ->
        {:error, "invalid time range: #{time_range}"}
    end
  end

  defp parse_time(time) do
    [time | _tail] = String.split(time, ".", parts: 2)

    case String.split(time, ":", parts: 3) do
      [hours] ->
        Time.from_iso8601(pad2(hours) <> ":00:00")

      [hours, minutes] ->
        Time.from_iso8601(pad2(hours) <> ":" <> pad2(minutes) <> ":00")

      [hours, minutes, seconds] ->
        Time.from_iso8601(pad2(hours) <> ":" <> pad2(minutes) <> ":" <> pad2(seconds))

      _ ->
        {:error, "invalid time: #{time}"}
    end
  end

  defp pad2(str_int) when byte_size(str_int) == 1, do: "0#{str_int}"
  defp pad2(str_int), do: str_int
end
