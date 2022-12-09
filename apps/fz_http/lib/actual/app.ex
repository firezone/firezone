defmodule Actual.Application do
  @moduledoc """
  The opposite of Wrapped.Application: Calls the actual Application modules.
  """

  def app do
    Application
  end
end
