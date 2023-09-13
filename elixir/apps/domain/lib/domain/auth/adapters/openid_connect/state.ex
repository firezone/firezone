defmodule Domain.Auth.Adapters.OpenIDConnect.State do
  def new do
    Domain.Crypto.random_token(32)
  end

  def equal?(state1, state2) do
    Plug.Crypto.secure_compare(state1, state2)
  end
end
