defmodule Portal.CaseTemplate do
  @moduledoc """
  Our wrapper for the ExUnit.CaseTemplate to provide SQL sandbox helpers to all tests.
  """
  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      setup tags do
        :ok = Sandbox.checkout(Portal.Repo)

        # Route Replica queries through the primary Repo's sandbox connection
        # so that Replica can see data created via Repo in the same test
        Portal.Repo.Replica.put_dynamic_repo(Portal.Repo)

        unless tags[:async] do
          Sandbox.mode(Portal.Repo, {:shared, self()})
        end

        :ok
      end
    end
  end
end
