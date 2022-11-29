defmodule Actual.Cache do
  @moduledoc """
  The opposite of Wrapped.Cache -- allows us to use the same
  cache() helper in bootup before Mox has stubbed anything.
  """

  def cache do
    FzHttp.Configurations.Cache
  end
end
