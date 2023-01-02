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

        FzHttp.GatewaysFixtures.setup_default_gateway()
        :ok
      end
    end
  end
end
