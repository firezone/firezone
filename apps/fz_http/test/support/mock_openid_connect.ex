defmodule OpenIDConnect.MockBehaviour do
  @moduledoc """
  Mock Behaviour for OpenIDConnect so that we can use Mox
  """
  @callback authorization_uri(any, map) :: String.t()
  @callback fetch_tokens(any, map) :: {:ok, any} | {:error, any}
  @callback verify(any, map) :: {:ok, any} | {:error, any}
end
