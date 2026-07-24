defmodule Portal.DeviceTrustChallengeFixtures do
  @moduledoc """
  Fixtures for the device-trust challenge flow: a test CA (plus an
  intermediate and an untrusted CA) and client-authentication leaves whose
  keys can sign a challenge nonce.
  """

  @dir Path.join([__DIR__, "device_trust_challenges"])

  def ca_pem, do: read("ca.pem")
  def ca_der, do: read("ca.der")
  def intermediate_pem, do: read("intermediate.pem")
  def intermediate_der, do: read("intermediate.der")
  def untrusted_ca_pem, do: read("untrusted_ca.pem")

  @doc """
  Returns `{leaf_der, private_key}` for the named leaf, where `private_key`
  is decoded and ready for `:public_key.sign/3`.

  Known leaves: `:rsa`, `:ec`, `:via_intermediate`, `:no_eku`, `:untrusted`.
  """
  def leaf(name) do
    {der_file, key_file} =
      case name do
        :rsa -> {"leaf_rsa.der", "leaf_rsa.key"}
        :ec -> {"leaf_ec.der", "leaf_ec.key"}
        :via_intermediate -> {"leaf_via_intermediate.der", "leaf_via_intermediate.key"}
        :no_eku -> {"leaf_no_eku.der", "leaf_no_eku.key"}
        :untrusted -> {"leaf_untrusted.der", "leaf_untrusted.key"}
      end

    {read(der_file), private_key(key_file)}
  end

  @doc """
  Builds a `device_trust_response` entry (base64 leaf + optional
  intermediates and a base64 signature over `nonce`) for the named leaf.
  """
  def response_entry(name, nonce, opts \\ []) do
    {leaf_der, private_key} = leaf(name)
    digest = Keyword.get(opts, :digest, :sha256)
    intermediates = Keyword.get(opts, :intermediates, [])

    signature = :public_key.sign(nonce, digest, private_key)

    %{
      "certs" => Enum.map([leaf_der | intermediates], &Base.encode64/1),
      "signed_challenge" => Base.encode64(signature)
    }
  end

  defp private_key(file) do
    [entry] = file |> read() |> :public_key.pem_decode()
    :public_key.pem_entry_decode(entry)
  end

  defp read(file), do: File.read!(Path.join(@dir, file))
end
