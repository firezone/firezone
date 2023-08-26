defmodule Domain.CaseTemplate do
  @moduledoc """
  Our wrapper for the ExUnit.CaseTemplate to provide SQL sandbox helpers to all tests.
  """
  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      setup tags do
        :ok = Sandbox.checkout(Domain.Repo)

        unless tags[:async] do
          Sandbox.mode(Domain.Repo, {:shared, self()})
        end

        :ok
      end
    end
  end
end
