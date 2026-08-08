defmodule Portal.Crl.Sync do
  @moduledoc """
  Fetches and caches one trust anchor's certificate revocation list.

  The connect path checks the cached rows rather than the network, so this
  worker owns every outbound request. A fetch that fails leaves the previous
  list in place: a CA that is briefly unreachable should not silently un-revoke
  the certificates it already published.
  """
  use Oban.Worker, queue: :crl_sync, max_attempts: 3
  alias Portal.Crypto.X509
  alias __MODULE__.Database
  require Logger

  # A CRL covers a whole CA, so it is larger than a certificate, but not
  # unbounded: refusing an oversized one keeps a hostile or broken endpoint
  # from being read into memory.
  @max_crl_bytes 5_000_000
  @request_timeout :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "certificate_id" => certificate_id}}) do
    case Database.fetch_certificate(account_id, certificate_id) do
      nil -> {:ok, :deleted}
      certificate -> refresh(certificate)
    end
  end

  defp refresh(certificate) do
    with {:ok, der} <- fetch(certificate.crl_url),
         :ok <- verify(der, certificate),
         {:ok, crl} <- decode(der),
         {:ok, issuer_hash} <- issuer_hash(der) do
      {:ok, count} = Database.replace_revocations(certificate, issuer_hash, crl)

      Logger.info("Refreshed certificate revocation list",
        account_id: certificate.account_id,
        trust_anchor_certificate_id: certificate.id,
        revoked_count: count
      )

      {:ok, :refreshed}
    else
      {:error, reason} ->
        Database.record_error(certificate, reason)

        Logger.warning("Failed to refresh certificate revocation list",
          account_id: certificate.account_id,
          trust_anchor_certificate_id: certificate.id,
          crl_url: certificate.crl_url,
          reason: inspect(reason)
        )

        {:ok, :failed}
    end
  end

  defp fetch(url) do
    case Req.get(url, receive_timeout: @request_timeout, max_redirects: 3, decode_body: false) do
      {:ok, %{status: 200, body: body}} when byte_size(body) <= @max_crl_bytes ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, :crl_too_large}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # A CRL is only worth as much as its signature: an unsigned or wrongly signed
  # list would let anyone who can answer the URL revoke a fleet, or hide a
  # revocation by serving an empty one.
  defp verify(der, certificate) do
    with {:ok, issuer_der} <- Database.issuer_der(certificate) do
      if X509.crl_signed_by?(der, issuer_der) do
        :ok
      else
        {:error, :crl_signature_invalid}
      end
    end
  end

  # Taken from the CRL itself rather than from the anchor: the list says who
  # signed it, and that is who its serials belong to.
  defp issuer_hash(der) do
    case X509.crl_issuer_hash(der) do
      nil -> {:error, :crl_issuer_unreadable}
      hash -> {:ok, hash}
    end
  end

  defp decode(der) do
    case X509.decode_crl(der) do
      {:ok, crl} -> {:ok, crl}
      {:error, :invalid} -> {:error, :crl_malformed}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Crypto.X509
    alias Portal.Safe

    def fetch_certificate(account_id, certificate_id) do
      from(c in Portal.TrustAnchorCertificate,
        where: c.account_id == ^account_id,
        where: c.id == ^certificate_id
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def issuer_der(certificate) do
      case X509.pem_decode(certificate.pem) do
        {:ok, [{_type, der, _info} | _rest]} -> {:ok, der}
        _other -> {:error, :anchor_unreadable}
      end
    end

    # The published list is the whole truth for its issuer, so the previous set
    # is replaced rather than merged: a serial the CA drops stops being
    # revoked, and one it adds starts.
    def replace_revocations(certificate, issuer_hash, crl) do
      now = DateTime.utc_now()

      rows =
        Enum.map(crl.revocations, fn revocation ->
          %{
            account_id: certificate.account_id,
            issuer_hash: issuer_hash,
            trust_anchor_certificate_id: certificate.id,
            serial: revocation.serial,
            revoked_at: revocation.revoked_at,
            reason: revocation.reason,
            inserted_at: now
          }
        end)

      Safe.transact(fn ->
        from(r in Portal.CrlRevocation,
          where: r.account_id == ^certificate.account_id,
          where: r.issuer_hash == ^issuer_hash
        )
        |> Safe.unscoped()
        |> Safe.delete_all()

        Safe.unscoped() |> Safe.insert_all(Portal.CrlRevocation, rows)

        from(c in Portal.TrustAnchorCertificate,
          where: c.account_id == ^certificate.account_id,
          where: c.id == ^certificate.id,
          update: [
            set: [
              crl_this_update: ^crl.this_update,
              crl_next_update: ^crl.next_update,
              crl_fetched_at: ^now,
              crl_error: nil
            ]
          ]
        )
        |> Safe.unscoped()
        |> Safe.update_all([])

        {:ok, length(rows)}
      end)
    end

    def record_error(certificate, reason) do
      from(c in Portal.TrustAnchorCertificate,
        where: c.account_id == ^certificate.account_id,
        where: c.id == ^certificate.id,
        update: [set: [crl_fetched_at: ^DateTime.utc_now(), crl_error: ^to_message(reason)]]
      )
      |> Safe.unscoped()
      |> Safe.update_all([])
    end

    defp to_message(reason) when is_binary(reason), do: String.slice(reason, 0, 255)
    defp to_message(reason), do: reason |> inspect() |> String.slice(0, 255)
  end
end
