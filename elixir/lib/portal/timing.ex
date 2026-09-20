defmodule Portal.Timing do
  @moduledoc """
  Timing helpers for security-sensitive flows.
  """

  @spec execute_with_constant_time((-> result), non_neg_integer()) :: result when result: term()
  def execute_with_constant_time(callback, constant_time) when is_function(callback, 0) do
    started_at = System.monotonic_time(:millisecond)
    result = callback.()

    case remaining_constant_time(started_at, constant_time) do
      0 -> :ok
      remaining_time -> :timer.sleep(remaining_time)
    end

    result
  end

  @doc """
  What is left of `constant_time` since `started_at`, a `System.monotonic_time(:millisecond)`
  reading.

  For callers that must not block while they wait, such as a channel that still has to serve
  the rest of its client. They schedule the answer this many milliseconds out instead.
  """
  @spec remaining_constant_time(integer(), non_neg_integer()) :: non_neg_integer()
  def remaining_constant_time(started_at, constant_time) do
    elapsed_time = System.monotonic_time(:millisecond) - started_at
    remaining_time = max(0, constant_time - elapsed_time)

    if remaining_time == 0 do
      log_constant_time_exceeded(constant_time, elapsed_time)
    end

    remaining_time
  end

  if Mix.env() in [:dev, :test] do
    defp log_constant_time_exceeded(_constant_time, _elapsed_time), do: :ok
  else
    require Logger

    defp log_constant_time_exceeded(constant_time, elapsed_time) do
      Logger.error("Execution took longer than the given constant time",
        constant_time: constant_time,
        elapsed_time: elapsed_time
      )
    end
  end
end
