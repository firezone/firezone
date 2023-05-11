defmodule Domain.Auth.Adapters.OpenIDConnect.State do
  def new do
    Domain.Crypto.rand_string()
  end

  def equal?(state1, state2) do
    state1 == state2
  end
end
