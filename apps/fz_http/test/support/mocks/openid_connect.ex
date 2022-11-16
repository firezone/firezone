defmodule OpenIDConnect.MockBehaviour do
  @moduledoc """
  Mock Behaviour for OpenIDConnect so that we can use Mox
  """
  @callback end_session_uri(any, map) :: String.t()
  @callback authorization_uri(any, map) :: String.t()
  @callback fetch_tokens(any, map) :: {:ok, any} | {:error, :fetch_tokens, any}
  @callback verify(any, map) :: {:ok, any} | {:error, :verify, any}
end
