defmodule FzWall.CLI.Helpers.HasFeature do
  @moduledoc """
  Used to retrieve if a particular feature is supported.
  """
  @min_port_version {5, 6, 8}
  def port_rules? do
    port_rules_supported?(:os.type(), :os.version())
  end

  defp port_rules_supported?({_, :linux}, version) when is_tuple(version),
    do: version > @min_port_version

  defp port_rules_supported?(_, _), do: false
end
