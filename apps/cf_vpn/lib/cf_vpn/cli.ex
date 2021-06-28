defmodule CfVpn.CLI do
  @moduledoc """
  Determines adapter to use for CLI commands.
  """

  def cli do
    Application.fetch_env!(:cf_vpn, :cli)
  end
end
