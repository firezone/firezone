defmodule Domain.Policies.Constraint.Evaluator do
  alias Domain.Repo
  alias Domain.Clients
  alias Domain.Policies.Constraint

  @days_of_week ~w[M T W R F S U]

  def conforms?(
        constraints,
        %Clients.Client{} = client
      )
      when is_list(constraints) do
    client = Repo.preload(client, :identity)
    Enum.all?(constraints, &conforms?(&1, client))
  end

  def conforms?(
        %Constraint{property: :remote_ip_location_region, operator: :is_in, values: values},
        %Clients.Client{} = client
      ) do
    client.last_seen_remote_ip_location_region in values
  end

  def conforms?(
        %Constraint{property: :remote_ip_location_region, operator: :is_not_in, values: values},
        %Clients.Client{} = client
      ) do
    client.last_seen_remote_ip_location_region not in values
  end

  def conforms?(
        %Constraint{property: :remote_ip, operator: :is_in_cidr, values: values},
        %Clients.Client{} = client
      ) do
    Enum.any?(values, fn cidr ->
      {:ok, cidr} = Domain.Types.CIDR.cast(cidr)
      Domain.Types.CIDR.contains?(client.last_seen_remote_ip, cidr)
    end)
  end

  def conforms?(
        %Constraint{property: :remote_ip, operator: :is_not_in_cidr, values: values},
        %Clients.Client{} = client
      ) do
    Enum.all?(values, fn cidr ->
      {:ok, cidr} = Domain.Types.CIDR.cast(cidr)
      not Domain.Types.CIDR.contains?(client.last_seen_remote_ip, cidr)
    end)
  end

  def conforms?(
        %Constraint{property: :provider_id, operator: :is_in, values: values},
        %Clients.Client{} = client
      ) do
    client = Repo.preload(client, :identity)
    client.identity.provider_id in values
  end

  def conforms?(
        %Constraint{property: :provider_id, operator: :is_not_in, values: values},
        %Clients.Client{} = client
      ) do
    client = Repo.preload(client, :identity)
    client.identity.provider_id not in values
  end

  def conforms?(
        %Constraint{
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
        today = DateTime.to_date(datetime)
        time = DateTime.to_time(datetime)
        day_of_the_week = Enum.at(@days_of_week, Date.day_of_week(today) - 1)

        case Map.fetch(dow_time_ranges, day_of_the_week) do
          {:ok, true} ->
            true

          {:ok, time_ranges} ->
            Enum.any?(time_ranges, fn {start_time, end_time} ->
              Time.compare(start_time, time) != :gt and Time.compare(time, end_time) != :gt
            end)

          :error ->
            false
        end

      {:error, _reason} ->
        false
    end
  end

  def parse_days_of_week_time_ranges(dows_time_ranges) do
    Enum.reduce(dows_time_ranges, {:ok, %{}}, fn dow_time_ranges, {:ok, acc} ->
      case parse_day_of_week_time_ranges(dow_time_ranges) do
        {:ok, {day, dow_time_ranges}} ->
          {_current_value, acc} =
            Map.get_and_update(acc, day, fn current_value ->
              {current_value, merge_time_ranges(current_value || [], dow_time_ranges)}
            end)

          {:ok, acc}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def parse_day_of_week_time_ranges(dow_time_ranges) do
    String.split(dow_time_ranges, "/", parts: 2)
    |> case do
      [day, time_ranges] when day in @days_of_week ->
        case parse_time_ranges(time_ranges) do
          {:ok, time_ranges} ->
            {:ok, {day, time_ranges}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, "invalid day of the week, must be one of #{Enum.join(@days_of_week, ", ")}"}
    end
  end

  defp merge_time_ranges(true, _time_ranges), do: true
  defp merge_time_ranges(_time_ranges, true), do: true

  defp merge_time_ranges(left_time_ranges, right_time_ranges) do
    cond do
      true in left_time_ranges ->
        true

      true in right_time_ranges ->
        true

      true ->
        left_time_ranges ++ right_time_ranges
    end
  end

  def parse_time_ranges(time_ranges) do
    String.split(time_ranges, ",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn time_range, {:ok, acc} ->
      case parse_time_range(time_range) do
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
    {:ok, true}
  end

  def parse_time_range(time_range) do
    with [start_time, end_time] <- String.split(time_range, "-", parts: 2),
         {:ok, start_time} <- Time.from_iso8601(start_time),
         {:ok, end_time} <- Time.from_iso8601(end_time),
         true <- Time.compare(start_time, end_time) != :gt do
      {:ok, {start_time, end_time}}
    else
      false ->
        {:error, "start of the time range must be less than or equal to the end of it"}

      _ ->
        {:error, "invalid time range: #{time_range}"}
    end
  end
end
