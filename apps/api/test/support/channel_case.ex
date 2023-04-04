defmodule API.ChannelCase do
  use ExUnit.CaseTemplate
  use Domain.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import API.ChannelCase

      # The default endpoint for testing
      @endpoint API.Endpoint
    end
  end
end
