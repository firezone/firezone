defmodule FgWall.CLI do
  @moduledoc """
  Determines adapter to use for CLI commands.
  """

  def cli do
    Application.fetch_env!(:fg_wall, :cli)
  end
end
