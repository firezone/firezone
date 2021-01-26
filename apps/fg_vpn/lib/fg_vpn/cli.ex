defmodule FgVpn.CLI do
  @moduledoc """
  Determines adapter to use for CLI commands.
  """

  def cli do
    Application.get_env(:fg_vpn, :cli)
  end
end
