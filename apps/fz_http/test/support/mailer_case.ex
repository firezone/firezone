defmodule FzHttpWeb.MailerCase do
  @moduledoc """
  A case template for Mailers.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias FzHttp.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import FzHttp.DataCase
      import FzHttp.TestHelpers

      use FzHttpWeb, :verified_routes
    end
  end

  setup tags do
    :ok = Sandbox.checkout(FzHttp.Repo)

    unless tags[:async] do
      Sandbox.mode(FzHttp.Repo, {:shared, self()})
    end

    :ok
  end
end
