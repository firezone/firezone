defmodule Portal.RevocationFixtures do
  @moduledoc "Test helpers for creating certificate revocation endpoints and records."

  import Portal.AccountFixtures
  alias Portal.Crypto.X509
  alias Portal.Repo

  @doc "Generate a CRL endpoint, accepting either an issuer name or an issuer certificate."
  def revocation_endpoint_fixture(attrs) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || account_fixture()
    crl_urls = Map.get(attrs, :crl_urls, ["http://crl.example.test/ca.crl"])

    attrs =
      attrs
      |> Map.put_new_lazy(:issuer, fn -> X509.subject(Map.fetch!(attrs, :issuer_der)) end)
      |> Map.put_new(:distribution_point, List.first(crl_urls) || "http://crl.example.test/ca.crl")
      |> Map.put(:crl_urls, crl_urls)
      |> Map.put(:account_id, account.id)
      |> Map.drop([:account, :issuer_der])

    Portal.RevocationEndpoint
    |> struct!(attrs)
    |> Repo.insert!()
  end

  @doc "Generate an OCSP endpoint for an issuer certificate."
  def ocsp_endpoint_fixture(attrs) do
    attrs = Enum.into(attrs, %{})
    urls = Map.get(attrs, :ocsp_urls, ["http://ocsp.example.test"])

    attrs
    |> Map.put(:ocsp_urls, urls)
    |> Map.put_new(:crl_urls, [])
    |> Map.put_new(:distribution_point, List.first(urls))
    |> revocation_endpoint_fixture()
  end

  @doc "Generate a revoked certificate serial for a CRL endpoint."
  def crl_revocation_fixture(attrs) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || account_fixture()

    attrs =
      attrs
      |> Map.put(:account_id, account.id)
      |> Map.put_new(:revoked_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.drop([:account])

    Portal.CrlRevocation
    |> struct!(attrs)
    |> Repo.insert!()
  end
end
