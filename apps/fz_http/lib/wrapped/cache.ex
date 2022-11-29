defmodule Wrapped.Cache do
  @moduledoc """
  Convenience wrapper for the Configurations Cache so it's possible
  to stub more easily.
  """

  def cache do
    Application.fetch_env!(:fz_http, :cache_module)
  end
end
