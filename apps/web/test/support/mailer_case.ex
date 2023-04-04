defmodule Web.MailerCase do
  @moduledoc """
  A case template for Mailers.
  """
  use ExUnit.CaseTemplate
  use Domain.CaseTemplate

  using do
    quote do
      alias Domain.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Domain.DataCase
      import Domain.TestHelpers

      use Web, :verified_routes
    end
  end
end
