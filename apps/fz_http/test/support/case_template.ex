defmodule FzHttp.CaseTemplate do
  @moduledoc """
  Our wrapper for the ExUnit.CaseTemplate to provide metaprogrammed
  helpers to all tests.
  """

  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      setup tags do
        :ok = Sandbox.checkout(FzHttp.Repo)

        unless tags[:async] do
          Sandbox.mode(FzHttp.Repo, {:shared, self()})
        end

        :ok
      end

      setup do
        # Global stub passthrough for functions we're not interested in stubbing
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
