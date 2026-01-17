defmodule Portal.Policies.Evaluator do
  alias Portal.Client

  @days_of_week ~w[M T W R F S U]

  def ensure_conforms([], %Client{}, _auth_provider_id) do
    {:ok, nil}
  end

  def ensure_conforms(conditions, %Client{} = client, auth_provider_id)
      when is_list(conditions) do
    conditions
    |> Enum.reduce({[], nil}, fn condition, {violated_properties, min_expires_at} ->
      if condition.property in violated_properties do
        {violated_properties, min_expires_at}
      else
        case fetch_conformation_expiration(condition, client, auth_provider_id) do
          {:ok, expires_at} ->
            {violated_properties, min_expires_at(expires_at, min_expires_at)}

          :error ->
            {[condition.property | violated_properties], min_expires_at}
        end
      end
    end)
    |> case do
      {[], expires_at} -> {:ok, expires_at}
      {violated_properties, _expires_at} -> {:error, Enum.reverse(violated_properties)}
    end
  end

  defp min_expires_at(expires_at, nil), do: expires_at

  defp min_expires_at(expires_at, min_expires_at),
    do: Enum.min([expires_at, min_expires_at], DateTime)

  # When region is unknown (nil), geo-based policies should fail conservatively
  def fetch_conformation_expiration(
        %{property: :remote_ip_location_region},
        %Client{last_seen_remote_ip_location_region: nil},
        _auth_provider_id
      ) do
    :error
  end

  def fetch_conformation_expiration(
        %{property: :remote_ip_location_region, operator: :is_in, values: values},
        %Client{} = client,
        _auth_provider_id
      ) do
    if client.last_seen_remote_ip_location_region in values do
      {:ok, nil}
    else
      :error
    end
  end

  def fetch_conformation_expiration(
        %{property: :remote_ip_location_region, operator: :is_not_in, values: values},
        %Client{} = client,
        _auth_provider_id
      ) do
    if client.last_seen_remote_ip_location_region in values do
      :error
    else
      {:ok, nil}
    end
  end

  def fetch_conformation_expiration(
        %{property: :remote_ip, operator: :is_in_cidr, values: values},
        %Client{} = client,
        _auth_provider_id
      ) do
    Enum.reduce_while(values, :error, fn cidr, :error ->
      {:ok, inet} = Portal.Types.INET.cast(cidr)
      cidr = %{inet | netmask: inet.netmask || Portal.Types.CIDR.max_netmask(inet)}

      if Portal.Types.CIDR.contains?(cidr, client.last_seen_remote_ip) do
        {:halt, {:ok, nil}}
      else
        {:cont, :error}
      end
    end)
  end

  def fetch_conformation_expiration(
        %{property: :remote_ip, operator: :is_not_in_cidr, values: values},
        %Client{} = client,
        _auth_provider_id
      ) do
    Enum.reduce_while(values, {:ok, nil}, fn cidr, {:ok, nil} ->
      {:ok, inet} = Portal.Types.INET.cast(cidr)
      cidr = %{inet | netmask: inet.netmask || Portal.Types.CIDR.max_netmask(inet)}

      if Portal.Types.CIDR.contains?(cidr, client.last_seen_remote_ip) do
        {:halt, :error}
      else
        {:cont, {:ok, nil}}
      end
    end)
  end

  def fetch_conformation_expiration(
        %{property: :auth_provider_id, operator: :is_in, values: values},
        %Client{},
        auth_provider_id
      ) do
    if auth_provider_id in values do
      {:ok, nil}
    else
      :error
    end
  end

  def fetch_conformation_expiration(
        %{property: :auth_provider_id, operator: :is_not_in, values: values},
        %Client{},
        auth_provider_id
      ) do
    if auth_provider_id in values do
      :error
    else
      {:ok, nil}
    end
  end

  def fetch_conformation_expiration(
        %{
          property: :client_verified,
          operator: :is,
          values: ["true"]
        },
        %Client{verified_at: verified_at},
        _auth_provider_id
      ) do
    if is_nil(verified_at) do
      :error
    else
      {:ok, nil}
    end
  end

  def fetch_conformation_expiration(
        %{
          property: :client_verified,
          operator: :is,
          values: _other
        },
        %Client{},
        _auth_provider_id
      ) do
    {:ok, nil}
  end

  def fetch_conformation_expiration(
        %{
          property: :current_utc_datetime,
          operator: :is_in_day_of_week_time_ranges,
          values: values
        },
        %Client{},
        _auth_provider_id
      ) do
    case find_day_of_the_week_time_range(values, DateTime.utc_now()) do
      nil -> :error
      expires_at -> {:ok, expires_at}
    end
  end

  def find_day_of_the_week_time_range(dow_time_ranges, datetime) do
    dow_time_ranges
    |> parse_days_of_week_time_ranges()
    |> case do
      {:ok, dow_time_ranges} ->
        dow_time_ranges
        |> Enum.find_value(fn {day, time_ranges} ->
          time_ranges = merge_joint_time_ranges(time_ranges)
          datetime_in_time_ranges?(datetime, day, time_ranges)
        end)

      {:error, _reason} ->
        nil
    end
  end

  @doc false
  # Merge ranges, eg. 4-11,11-22 = 4-22
  def merge_joint_time_ranges(time_ranges) do
    merged_time_ranges =
      Enum.reduce(time_ranges, [], fn {start_time, end_time, timezone}, acc ->
        index =
          Enum.find_index(acc, fn {acc_start_time, acc_end_time, acc_timezone} ->
            acc_timezone == timezone and
              (time_in_range?(start_time, acc_start_time, acc_end_time) or
                 time_in_range?(end_time, acc_start_time, acc_end_time) or
                 time_in_range?(acc_start_time, start_time, end_time) or
                 time_in_range?(acc_end_time, start_time, end_time))
          end)

        if index == nil do
          [{start_time, end_time, timezone}] ++ acc
        else
          {{acc_start_time, acc_end_time, _timezone}, acc} = List.pop_at(acc, index)
          start_time = Enum.min([start_time, acc_start_time], Time)
          end_time = Enum.max([end_time, acc_end_time], Time)
          [{start_time, end_time, timezone}] ++ acc
        end
      end)
      |> Enum.reverse()

    if merged_time_ranges == time_ranges do
      merged_time_ranges
    else
      merge_joint_time_ranges(merged_time_ranges)
    end
  end

  defp time_in_range?(time, range_start, range_end) do
    Time.compare(range_start, time) in [:lt, :eq] and
      Time.compare(time, range_end) in [:lt, :eq]
  end

  defp datetime_in_time_ranges?(datetime, day_of_the_week, time_ranges) do
    Enum.find_value(time_ranges, fn {start_time, end_time, timezone} ->
      datetime = DateTime.shift_zone!(datetime, timezone, Tzdata.TimeZoneDatabase)
      date = DateTime.to_date(datetime)
      time = DateTime.to_time(datetime)

      if Enum.at(@days_of_week, Date.day_of_week(date) - 1) == day_of_the_week and
           Time.compare(start_time, time) != :gt and Time.compare(time, end_time) != :gt do
        DateTime.new!(date, end_time, timezone, Tzdata.TimeZoneDatabase)
        |> DateTime.shift_zone!("UTC", Tzdata.TimeZoneDatabase)
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
