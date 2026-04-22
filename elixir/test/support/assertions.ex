defmodule Portal.Test.Assertions do
  @moduledoc false

  @doc """
  Waits for an ExUnit assertion to pass before timing out.
  """
  def wait_for(assertion_callback, wait_seconds \\ 2) do
    started_at = System.monotonic_time(:millisecond)
    wait_for(assertion_callback, wait_seconds, started_at)
  end

  defp wait_for(assertion_callback, wait_seconds, started_at) do
    try do
      assertion_callback.()
    rescue
      e in [ExUnit.AssertionError] ->
        time_spent = System.monotonic_time(:millisecond) - started_at

        if time_spent > :timer.seconds(wait_seconds) do
          reraise(e, __STACKTRACE__)
        else
          time_spent
          |> div(10)
          |> max(100)
          |> Process.sleep()

          wait_for(assertion_callback, wait_seconds, started_at)
        end
    end
  end
end
