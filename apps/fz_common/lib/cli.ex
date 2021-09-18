defmodule FzCommon.CLI do
  @moduledoc """
  Handles low-level CLI facilities.
  """

  require Logger

  def bash(cmd) do
    System.cmd("/bin/sh", ["-c", cmd], stderr_to_stdout: true)
  end

  def exec(cmd, opts) when is_list(opts) do
    case bash(cmd) do
      {result, 0} ->
        result

      {error, exit_code} ->
        error_msg = """
          Error executing command #{cmd}.
          Exit code: #{exit_code}
          Error message:
          #{error}
        """

        if opts[:suppress] do
          Logger.warn(error_msg)
        else
          raise error_msg
        end

        error_msg
    end
  end

  def exec(cmd) do
    exec(cmd, suppress: true)
  end

  def exec!(cmd) do
    exec(cmd, suppress: false)
  end
end
