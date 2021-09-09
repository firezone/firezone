defmodule FzCommon.CLI do
  @moduledoc """
  Handles low-level CLI facilities.
  """

  def bash(cmd) do
    System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)
  end

  def exec!(cmd) do
    case bash(cmd) do
      {result, 0} ->
        result

      {error, exit_code} ->
        raise """
        Error executing command #{cmd}. Exited with code #{exit_code} and error #{error}.
        FireZone cannot recover from this error.
        """
    end
  end
end
