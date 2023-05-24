defmodule Domain.Auth.Adapters.OpenIDConnect.PKCE do
  def code_challenge_method do
    :S256
  end

  def code_verifier do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  def code_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end
end
