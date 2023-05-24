defmodule API.ConnCase do
  use ExUnit.CaseTemplate
  use Domain.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint API.Endpoint

      use API, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import API.ConnCase
    end
  end
end
