defmodule FzVpn.CLI do
  @moduledoc """
  Determines adapter to use for CLI commands.
  """

  def cli do
    Application.fetch_env!(:fz_vpn, :cli)
  end
end
