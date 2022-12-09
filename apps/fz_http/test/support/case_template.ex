defmodule FzHttp.CaseTemplate do
  @moduledoc """
  Our wrapper for the ExUnit.CaseTemplate to provide metaprogrammed
  helpers to all tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      setup do
        # Global stub passthrough for functions we're not interested in stubbing
        Mox.stub(Application.Mock, :fetch_env!, fn app, key ->
          Application.fetch_env!(app, key)
        end)

        Mox.stub(Cache.Mock, :get!, fn key ->
          FzHttp.Configurations.Cache.get!(key)
        end)

        Mox.stub(Cache.Mock, :put!, fn key, val ->
          FzHttp.Configurations.Cache.put!(key, val)
        end)

        :ok
      end
    end
  end
end
