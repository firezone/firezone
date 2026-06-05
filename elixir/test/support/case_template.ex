defmodule Portal.CaseTemplate do
  @moduledoc """
  Injects the SQL sandbox setup into our ExUnit case templates.

  This is a plain `__using__/1` macro rather than an `ExUnit.CaseTemplate` on
  purpose: nesting a case template inside another case template makes ExUnit
  emit a duplicate `__ex_unit__(:setup, ...)` clause, which the compiler flags
  as redundant.
  """

  defmacro __using__(_opts) do
    quote do
      setup tags do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Portal.Repo)

        unless tags[:async] do
          Ecto.Adapters.SQL.Sandbox.mode(Portal.Repo, {:shared, self()})
        end

        :ok
      end
    end
  end
end
