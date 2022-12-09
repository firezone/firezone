defmodule Application.MockBehaviour do
  @moduledoc """
  Mock Behaviour for Application fetch_env!/2.
  """
  @callback fetch_env!(atom(), atom()) :: any()
end
