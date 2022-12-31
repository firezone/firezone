defmodule FzHttpWeb.MailerCase do
  @moduledoc """
  A case template for Mailers.
  """
  use ExUnit.CaseTemplate
  use FzHttp.CaseTemplate

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
end
