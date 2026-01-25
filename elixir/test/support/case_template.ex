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
        :ok = Sandbox.checkout(Portal.Repo.Replica)

        unless tags[:async] do
          Sandbox.mode(Portal.Repo, {:shared, self()})
          Sandbox.mode(Portal.Repo.Replica, {:shared, self()})
        end

        :ok
      end
    end
  end
end
