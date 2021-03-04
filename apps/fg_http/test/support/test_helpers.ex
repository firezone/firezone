defmodule FgHttp.TestHelpers do
  @moduledoc """
  Test setup helpers
  """
  alias FgHttp.Fixtures

  def create_device(_) do
    device = Fixtures.device()
    {:ok, device: device}
  end
end
