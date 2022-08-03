defmodule FzWall.CLI.Helpers.HasFeature do
  @moduledoc """
  Used to retrieve if a particular feature is supported.
  """
  import FzCommon.CLI
  require Logger

  @min_port_version ">5.6.8"
  def port_rules? do
    # We are Elixir's Version here that is based on semver but Linux's
    # kernel doesn't use semver, this is just for convinience.
    case get_kernel_version() do
      {:ok, result} ->
        Version.match?(result, @min_port_version, allow_pre: true)

      :err ->
        Logger.warn("uname is needed to check kernel version to enable port-based rules")
        false
    end
  end

  defp get_kernel_version do
    case bash("uname -r") do
      {result, 0} ->
        {:ok, String.trim(result)}

      {_, _exit_code} ->
        :err
    end
  end
end
