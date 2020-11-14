defmodule FgHttp.MockHelpers do
  @moduledoc """
  Helpers for test life cycle
  """

  import ExUnit.Callbacks

  def mock_enable_signup do
    mock_disable_signup(false)
  end

  def mock_disable_signup do
    mock_disable_signup(true)
  end

  def mock_disable_signup(val) when val in [true, false] do
    old_val = Application.get_env(:fg_http, :disable_signup)
    Application.put_env(:fg_http, :disable_signup, val)
    on_exit(fn -> Application.put_env(:fg_http, :disable_signup, old_val) end)
  end
end
