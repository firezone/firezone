defmodule FzWall.CLI do
  @moduledoc """
  Determines adapter to use for CLI commands.
  """

  def cli do
    Application.fetch_env!(:fz_wall, :cli)
  end
end
