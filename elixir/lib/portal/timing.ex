defmodule Portal.Timing do
  @moduledoc """
  Timing helpers for security-sensitive flows.
  """

  require Logger

  @spec execute_with_constant_time((-> result), non_neg_integer()) :: result when result: term()
  def execute_with_constant_time(callback, constant_time) when is_function(callback, 0) do
    start_time = System.monotonic_time(:millisecond)
    result = callback.()
    end_time = System.monotonic_time(:millisecond)

    elapsed_time = end_time - start_time
    remaining_time = max(0, constant_time - elapsed_time)

    if remaining_time > 0 do
      :timer.sleep(remaining_time)
    else
      log_constant_time_exceeded(constant_time, elapsed_time)
    end

    result
  end

  if Mix.env() in [:dev, :test] do
    defp log_constant_time_exceeded(_constant_time, _elapsed_time), do: :ok
  else
    defp log_constant_time_exceeded(constant_time, elapsed_time) do
      Logger.error("Execution took longer than the given constant time",
        constant_time: constant_time,
        elapsed_time: elapsed_time
      )
    end
  end
end
