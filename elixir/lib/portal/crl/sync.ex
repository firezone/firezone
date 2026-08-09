defmodule Portal.Crl.Sync do
  @moduledoc """
  Fetches and caches the certificate revocation list published by one issuer.

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
  def perform(%Oban.Job{
        args: %{
          "account_id" => account_id,
          "issuer" => encoded_issuer,
          "distribution_point" => distribution_point
        }
      }) do
    with {:ok, issuer} <- Base.decode64(encoded_issuer),
         endpoint when not is_nil(endpoint) <-
           Database.fetch_endpoint(account_id, issuer, distribution_point) do
      refresh(endpoint)
    else
      _other -> {:ok, :deleted}
    end
  end

  defp refresh(endpoint) do
    case fetch_and_verify(endpoint) do
      {:ok, crl} ->
        {:ok, {count, newly_revoked}} = Database.replace_revocations(endpoint, crl)
        notify_revoked(endpoint, newly_revoked)

        Logger.info("Refreshed certificate revocation list",
          account_id: endpoint.account_id,
          issuer: X509.describe_name(endpoint.issuer),
          distribution_point: endpoint.distribution_point,
          revoked_count: count,
          newly_revoked_count: MapSet.size(newly_revoked)
        )

        {:ok, :refreshed}

      {:error, reason} ->
        Database.record_error(endpoint, reason)

        Logger.warning("Failed to refresh certificate revocation list",
          account_id: endpoint.account_id,
          issuer: X509.describe_name(endpoint.issuer),
          distribution_point: endpoint.distribution_point,
          reason: inspect(reason)
        )

        {:ok, :failed}
    end
  end

  # The connect path refuses a revoked certificate, but only at the next
  # connect. A device already holding a session would keep it until then, which
  # for a long-lived tunnel can be days, so the sessions are cut here instead.
  #
  # Only serials that were not already cached are acted on: a device revoked in
  # an earlier run cannot have reconnected attested, so re-notifying it every
  # hour would deliver to nobody.
  #
  # The certificate is named in the message rather than acted on here, because
  # the device columns record the last certificate a device ever presented, not
  # the one the current session is riding on. Only the channel knows that, so it
  # is left to decide whether the revocation is about it.
  defp notify_revoked(endpoint, newly_revoked) do
    if MapSet.size(newly_revoked) > 0 do
      Enum.each(Database.devices_with_serials(endpoint, newly_revoked), fn device ->
        notify(device, endpoint.issuer)
      end)
    end
  end

  # Delivered on the device id, which is what the channel registers under. The
  # token would work today but not once a certificate can authenticate a user on
  # its own, and it is written by the batched session flush so it can lag a
  # reconnect by seconds.
  defp notify(device, issuer) do
    Portal.PG.deliver(
      device.id,
      {:certificate_revoked, issuer, device.last_attested_cert_serial}
    )
  end

  # The addresses are alternates for the same list, so a transport failure moves
  # on to the next while anything the list itself says about its contents is
  # final. Retrying a rejected list at another address would only fetch the same
  # bytes again.
  defp fetch_and_verify(endpoint) do
    Enum.reduce_while(endpoint.crl_urls, {:error, :no_crl_url}, fn url, _last ->
      url |> fetch_one(endpoint) |> next_or_stop()
    end)
  end

  defp next_or_stop({:ok, crl}), do: {:halt, {:ok, crl}}

  defp next_or_stop({:error, reason}) do
    if address_fault?(reason) do
      {:cont, {:error, reason}}
    else
      {:halt, {:error, reason}}
    end
  end

  # Whether the failure was the address rather than the list. An address that
  # did not answer says nothing about the alternates; a list that answered and
  # was unusable would be the same bytes at any of them.
  defp address_fault?(:unsupported_url_scheme), do: true
  defp address_fault?(:crl_too_large), do: true
  defp address_fault?({:http_status, _status}), do: true
  defp address_fault?(reason) when is_binary(reason), do: true
  defp address_fault?(_reason), do: false

  defp fetch_one(url, endpoint) do
    with :ok <- supported_scheme(url),
         {:ok, der} <- fetch(url),
         :ok <- issued_by_expected_ca(der, endpoint),
         :ok <- verify_signature(der, endpoint),
         {:ok, crl} <- decode(der),
         :ok <- covers_this_partition(crl, url) do
      {:ok, crl}
    end
  end

  # Named rather than reported as a transport failure: ldap:// is what AD CS
  # publishes by default inside a domain, and an administrator who sees the
  # scheme knows what to do about it.
  defp supported_scheme(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      :ok
    else
      {:error, :unsupported_url_scheme}
    end
  end

  defp fetch(url) do
    options =
      [receive_timeout: @request_timeout, max_redirects: 3, decode_body: false] ++ request_opts()

    case Req.get(url, options) do
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

  # The address was learned from a certificate, so whatever answers it must
  # still be the list belonging to that certificate's issuer. Without this a
  # wrong or hostile URL would have its serials cached under an issuer they
  # were never published for, revoking certificates that were never revoked.
  defp issued_by_expected_ca(der, endpoint) do
    if X509.crl_issuer(der) == endpoint.issuer do
      :ok
    else
      {:error, :crl_issuer_mismatch}
    end
  end

  # A CRL is only worth as much as its signature: an unsigned or wrongly signed
  # list would let anyone who can answer the URL revoke a fleet, or hide a
  # revocation by serving an empty one. Verified against whichever anchor bears
  # the issuer's name rather than against the one a device happened to chain
  # through, which for an account holding both a root and its intermediate is
  # not reliably the CA that signed the list.
  defp verify_signature(der, endpoint) do
    endpoint.account_id
    |> Database.anchor_ders()
    |> Enum.filter(&(X509.subject(&1) == endpoint.issuer))
    |> Enum.any?(&X509.crl_signed_by?(der, &1))
    |> case do
      true -> :ok
      false -> {:error, :crl_signature_invalid}
    end
  end

  defp decode(der) do
    case X509.decode_crl(der) do
      {:ok, crl} -> {:ok, crl}
      {:error, :invalid} -> {:error, :crl_malformed}
    end
  end

  # An Issuing Distribution Point does not by itself mean the list is partial: a
  # CA may stamp one on a complete list purely to name itself. Only the fields
  # that genuinely exclude our leaves are rejected, and where the extension names
  # a distribution point it has to be the one we followed, or we would cache
  # another partition's serials under this one.
  defp covers_this_partition(crl, url) do
    cond do
      crl.scope.delta? ->
        {:error, :crl_is_delta}

      crl.scope.excludes != [] ->
        {:error, {:crl_excludes, crl.scope.excludes}}

      crl.scope.distribution_points != [] and url not in crl.scope.distribution_points ->
        {:error, :crl_wrong_partition}

      true ->
        :ok
    end
  end

  defp request_opts, do: Portal.Config.fetch_env!(:portal, __MODULE__)[:req_opts] || []

  defmodule Database do
    import Ecto.Query
    alias Portal.Crypto.X509
    alias Portal.Safe

    def fetch_endpoint(account_id, issuer, distribution_point) do
      from(e in Portal.RevocationEndpoint,
        where: e.account_id == ^account_id,
        where: e.issuer == ^issuer,
        where: e.distribution_point == ^distribution_point
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def anchor_ders(account_id) do
      from(c in Portal.TrustAnchorCertificate,
        # The features table is global per-deployment state with no account_id.
        # credo:disable-for-next-line Credo.Check.Warning.MissingAccountIdInJoin
        join: f in Portal.Features,
        on: f.feature == :trust_anchors and f.enabled == true,
        where: c.account_id == ^account_id,
        select: c.pem
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.flat_map(&decode_pem/1)
    end

    # The published list is the whole truth for its issuer, so the previous set
    # is replaced rather than merged: a serial the CA drops stops being
    # revoked, and one it adds starts.
    def replace_revocations(endpoint, crl) do
      now = DateTime.utc_now()

      rows =
        Enum.map(crl.revocations, fn revocation ->
          %{
            account_id: endpoint.account_id,
            issuer: endpoint.issuer,
            distribution_point: endpoint.distribution_point,
            serial: revocation.serial,
            revoked_at: revocation.revoked_at,
            reason: revocation.reason,
            inserted_at: now
          }
        end)

      Safe.transact(fn ->
        # Read before the replace so the rows this fetch adds can be told from
        # the ones already cached. Everything is rewritten either way, so the
        # difference is not recoverable afterwards.
        already_revoked =
          endpoint
          |> partition_query()
          |> select([r], r.serial)
          |> Safe.unscoped()
          |> Safe.all()
          |> MapSet.new()

        newly_revoked =
          rows
          |> MapSet.new(& &1.serial)
          |> MapSet.difference(already_revoked)

        endpoint
        |> partition_query()
        |> Safe.unscoped()
        |> Safe.delete_all()

        Safe.unscoped() |> Safe.insert_all(Portal.CrlRevocation, rows)

        endpoint
        |> endpoint_query()
        |> update(
          set: [
            crl_number: ^crl.number,
            crl_this_update: ^crl.this_update,
            crl_next_update: ^crl.next_update,
            crl_fetched_at: ^now,
            crl_error: nil,
            updated_at: ^now
          ]
        )
        |> Safe.unscoped()
        |> Safe.update_all([])

        {:ok, {length(rows), newly_revoked}}
      end)
    end

    # Matched on the issuer as well as the serial: a serial only identifies a
    # certificate together with whoever issued it, so a device holding the same
    # serial from a different CA is a different certificate entirely.
    def devices_with_serials(endpoint, serials) do
      from(d in Portal.Device,
        where: d.account_id == ^endpoint.account_id,
        where: d.last_attested_cert_issuer == ^endpoint.issuer,
        where: d.last_attested_cert_serial in ^MapSet.to_list(serials)
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def record_error(endpoint, reason) do
      now = DateTime.utc_now()

      endpoint
      |> endpoint_query()
      |> update(
        set: [crl_fetched_at: ^now, crl_error: ^to_message(reason), updated_at: ^now]
      )
      |> Safe.unscoped()
      |> Safe.update_all([])
    end

    # Scoped to one partition: replacing every row for the issuer would wipe the
    # partitions this fetch never saw.
    defp partition_query(endpoint) do
      from(r in Portal.CrlRevocation,
        where: r.account_id == ^endpoint.account_id,
        where: r.issuer == ^endpoint.issuer,
        where: r.distribution_point == ^endpoint.distribution_point
      )
    end

    defp endpoint_query(endpoint) do
      from(e in Portal.RevocationEndpoint,
        where: e.account_id == ^endpoint.account_id,
        where: e.issuer == ^endpoint.issuer,
        where: e.distribution_point == ^endpoint.distribution_point
      )
    end

    defp decode_pem(pem) do
      case X509.pem_decode(pem) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&X509.certificate_entry?/1)
          |> Enum.map(fn {_type, der, _info} -> der end)

        {:error, _reason} ->
          []
      end
    end

    defp to_message(reason) when is_binary(reason), do: String.slice(reason, 0, 255)
    defp to_message(reason), do: reason |> inspect() |> String.slice(0, 255)
  end
end
