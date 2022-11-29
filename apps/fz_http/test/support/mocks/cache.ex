defmodule Cache.MockBehaviour do
  @moduledoc """
  Mock behavior for stubbing/expecting in tests.
  """
  @callback get!(atom()) :: any()
  @callback put!(atom(), any()) :: any()
end
