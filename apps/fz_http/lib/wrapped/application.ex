defmodule Wrapped.Application do
  @moduledoc """
  Wraps Application so it can be stubbed easily for tests that use Mox to
  mock Application.fetch_env!/2 calls.
  """

  @app :fz_http

  def app do
    Application.fetch_env!(@app, :application_module)
  end
end
