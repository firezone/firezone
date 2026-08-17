defmodule Portal.Ocsp.Sync do
  @moduledoc """
  Asks an issuer's OCSP responder about the certificates its devices hold.

  A CRL is one fetch covering a whole CA. OCSP answers one certificate at a
  time, so this asks only about the certificates devices have actually
  presented, and only about those whose cached answer has run out. Doing it here
  rather than at connect keeps a reconnect storm from becoming a request storm at
  the responder, which is commonly billed per query.
  """
  use Oban.Worker, queue: :ocsp_sync, max_attempts: 3
  alias Portal.Crypto.Ocsp
  alias Portal.Crypto.X509
  alias __MODULE__.Database
  require Logger

  @max_response_bytes 100_000
  @request_timeout :timer.seconds(30)
  @content_type "application/ocsp-request"

  # Refreshed before the answer runs out, so a cached status is never read past
  # its own expiry just because the scheduler ticked late.
  @refresh_margin_seconds 3600

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "account_id" => account_id,
          "issuer" => encoded_issuer,
          "distribution_point" => distribution_point
        } = args
      }) do
    with true <- Portal.Features.enabled?(:trust_anchors),
         {:ok, issuer} <- Base.decode64(encoded_issuer),
         endpoint when not is_nil(endpoint) <-
           Database.fetch_endpoint(account_id, issuer, distribution_point) do
      refresh(endpoint, Map.get(args, "serial"))
    else
      _other -> {:ok, :deleted}
    end
  end

  @doc """
  Queues a check of one certificate, for a device that has just connected.

  The scheduled run only asks about certificates whose cached answer has run
  out, which leaves two gaps a connect can close. A certificate nobody has ever
  asked about is let on unchecked until the next run, and a certificate revoked
  during a long-lived session is not noticed until its cached answer expires.

  Deduplicated on the certificate rather than the device, so a reconnect storm
  across a fleet holding the same certificate is one question, and made unique
  for an hour so a device that keeps reconnecting does not keep paying for
  answers a responder bills per query.
  """
  @spec enqueue_check(Ecto.UUID.t(), binary(), String.t()) :: :ok
  def enqueue_check(account_id, issuer, serial) do
    if Portal.Features.enabled?(:trust_anchors) do
      Database.ocsp_distribution_points(account_id, issuer)
      |> Enum.each(fn distribution_point ->
        %{
          account_id: account_id,
          issuer: Base.encode64(issuer),
          distribution_point: distribution_point,
          serial: serial
        }
        |> new(unique: [period: {1, :hour}, states: Oban.Job.states() -- [:discarded]])
        |> Oban.insert()
      end)
    end

    :ok
  end

  defp refresh(endpoint, serial) do
    case Database.issuer_certificate(endpoint) do
      nil ->
        record_failure(endpoint, :issuer_certificate_missing)

      issuer_der ->
        due = due_serials(endpoint, serial)

        case ask_each(endpoint, issuer_der, due) do
          :ok ->
            Database.record_success(endpoint)

            Logger.info("Refreshed OCSP statuses",
              account_id: endpoint.account_id,
              issuer: X509.describe_name(endpoint.issuer),
              asked_count: length(due)
            )

            {:ok, :refreshed}

          {:error, reason} ->
            record_failure(endpoint, reason)
        end
    end
  end

  # A connect names the one certificate it is asking about, and is asked
  # unconditionally: the point of the check is to notice a revocation the cached
  # answer is too old to know about.
  defp due_serials(_endpoint, serial) when is_binary(serial), do: [serial]

  defp due_serials(endpoint, nil) do
    Database.due_serials(
      endpoint,
      DateTime.add(DateTime.utc_now(), @refresh_margin_seconds, :second)
    )
  end

  # Stops at the first failure that is about the responder rather than about one
  # certificate. Each question is its own request, retried four times over half a
  # minute each, so walking the whole fleet through a responder that is down
  # would take the job hours and the next hour's job would pile in behind it.
  defp ask_each(endpoint, issuer_der, serials) do
    Enum.reduce_while(serials, :ok, fn serial, _acc ->
      endpoint |> ask(issuer_der, serial) |> continue_or_halt()
    end)
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}

  defp continue_or_halt({:error, reason}) do
    if certificate_fault?(reason) do
      {:cont, :ok}
    else
      {:halt, {:error, reason}}
    end
  end

  # About one certificate, so the rest of the fleet is still worth asking about.
  defp certificate_fault?(:unknown_certificate), do: true
  defp certificate_fault?(:no_answer), do: true
  defp certificate_fault?(_reason), do: false

  defp record_failure(endpoint, reason) do
    Database.record_error(endpoint, reason)

    # Logged as an error rather than a warning: an endpoint that keeps failing
    # means revocation is not being enforced for that CA.
    Logger.error("Failed to refresh OCSP statuses",
      account_id: endpoint.account_id,
      issuer: X509.describe_name(endpoint.issuer),
      reason: inspect(reason)
    )

    {:ok, :failed}
  end

  defp ask(endpoint, issuer_der, serial) do
    with {:ok, request} <- Ocsp.build_request(issuer_der, serial),
         {:ok, body} <- post(endpoint.ocsp_urls, request),
         {:ok, status} <- read(body, issuer_der, serial, endpoint) do
      store(endpoint, serial, status)
    end
  end

  # A responder or a cache in front of it can replay an older answer, and two
  # runs can finish out of order, either of which would otherwise let a stale
  # "good" overwrite a revocation we have already seen.
  defp store(endpoint, serial, status) do
    previous = Database.status(endpoint, serial)

    if stale?(status, previous) do
      :ok
    else
      Database.put_status(endpoint, serial, status)
      if newly_revoked?(status, previous), do: notify(endpoint, serial)
      :ok
    end
  end

  defp stale?(_status, nil), do: false
  defp stale?(%{this_update: nil}, _previous), do: false
  defp stale?(_status, %{this_update: nil}), do: false

  defp stale?(%{this_update: incoming}, %{this_update: cached}) do
    DateTime.compare(incoming, cached) == :lt
  end

  defp newly_revoked?(%{status: :revoked}, nil), do: true
  defp newly_revoked?(%{status: :revoked}, %{status: status}), do: status != "revoked"
  defp newly_revoked?(_status, _previous), do: false

  # The same message the list path sends, so a session riding on the revoked
  # certificate is cut rather than waiting for the device to reconnect.
  defp notify(endpoint, serial) do
    Enum.each(Database.devices_with_serial(endpoint, serial), fn device ->
      Portal.PG.deliver(device.id, {:certificate_revoked, endpoint.issuer, serial})
    end)
  end

  # A responder that has no record of a certificate our own anchor issued is
  # answering about a CA it does not serve, or the question was built wrong.
  # Either way it is our bug, not the device's, so it is logged loudly and the
  # certificate is left without a cached answer rather than marked bad.
  defp read(body, issuer_der, serial, endpoint) do
    case Ocsp.read_response(body, issuer_der, serial) do
      {:ok, status} ->
        {:ok, status}

      {:error, :unknown_certificate} ->
        Logger.error("OCSP responder does not know a certificate from this CA",
          account_id: endpoint.account_id,
          issuer: X509.describe_name(endpoint.issuer),
          cert_serial: serial
        )

        {:error, :unknown_certificate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post([], _request), do: {:error, :no_ocsp_url}

  defp post([url | rest], request) do
    case post_one(url, request) do
      {:ok, body} -> {:ok, body}
      {:error, reason} when rest == [] -> {:error, reason}
      {:error, _reason} -> post(rest, request)
    end
  end

  defp post_one(url, request) do
    if String.starts_with?(url, ["http://", "https://"]) do
      send_request(url, request)
    else
      {:error, :unsupported_url_scheme}
    end
  end

  defp send_request(url, request) do
    options =
      [
        headers: [{"content-type", @content_type}],
        body: request,
        receive_timeout: @request_timeout,
        max_redirects: 3,
        decode_body: false,
        # An OCSP question is idempotent, so unlike a general POST it is safe to
        # retry. Req's default only retries safe methods.
        retry: :transient
      ] ++ request_opts()

    case Req.post(url, options) do
      {:ok, %{status: 200, body: body}} when byte_size(body) <= @max_response_bytes ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, :ocsp_response_too_large}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, %Portal.Req.SSRFProtection.UnsafeURLError{} = exception} ->
        {:error, {:blocked_address, Exception.message(exception)}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp request_opts, do: Portal.Config.fetch_env!(:portal, __MODULE__)[:req_opts] || []

  defmodule Database do
    import Ecto.Query
    alias Portal.Crypto.X509
    alias Portal.Revocation.Failure
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

    def ocsp_distribution_points(account_id, issuer) do
      from(e in Portal.RevocationEndpoint,
        where: e.account_id == ^account_id,
        where: e.issuer == ^issuer,
        where: e.ocsp_urls != [],
        where: e.is_disabled == false,
        select: e.distribution_point
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    # The request names the certificate by hashes of its issuer's name and key,
    # so the CA's own certificate has to be on hand to ask about anything.
    def issuer_certificate(endpoint) do
      from(c in Portal.TrustAnchorCertificate,
        where: c.account_id == ^endpoint.account_id,
        select: c.pem
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.flat_map(&decode_pem/1)
      |> Enum.find(&(X509.subject(&1) == endpoint.issuer))
    end

    # Only certificates devices have actually presented, and only those whose
    # answer has run out: OCSP costs a request each, so re-asking about one that
    # is still current is a request nobody needed.
    def due_serials(endpoint, due_at) do
      from(d in Portal.Device,
        left_join: s in Portal.OcspStatus,
        on:
          s.account_id == d.account_id and s.issuer == d.last_attested_cert_issuer and
            s.serial == d.last_attested_cert_serial,
        where: d.account_id == ^endpoint.account_id,
        where: d.last_attested_cert_issuer == ^endpoint.issuer,
        where: not is_nil(d.last_attested_cert_serial),
        where: is_nil(s.serial) or is_nil(s.next_update) or s.next_update <= ^due_at,
        distinct: true,
        select: d.last_attested_cert_serial
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def status(endpoint, serial) do
      from(s in Portal.OcspStatus,
        where: s.account_id == ^endpoint.account_id,
        where: s.issuer == ^endpoint.issuer,
        where: s.serial == ^serial
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def devices_with_serial(endpoint, serial) do
      from(d in Portal.Device,
        where: d.account_id == ^endpoint.account_id,
        where: d.last_attested_cert_issuer == ^endpoint.issuer,
        where: d.last_attested_cert_serial == ^serial
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def put_status(endpoint, serial, status) do
      now = DateTime.utc_now()

      row = %{
        account_id: endpoint.account_id,
        issuer: endpoint.issuer,
        serial: serial,
        status: Atom.to_string(status.status),
        revoked_at: status.revoked_at,
        reason: status.reason,
        produced_at: status.produced_at,
        this_update: status.this_update,
        next_update: status.next_update,
        updated_at: now
      }

      Safe.unscoped()
      |> Safe.insert_all(Portal.OcspStatus, [row],
        on_conflict: {:replace_all_except, [:account_id, :issuer, :serial]},
        conflict_target: [:account_id, :issuer, :serial]
      )
    end

    def record_success(endpoint) do
      now = DateTime.utc_now()

      fields =
        [ocsp_checked_at: now, ocsp_error: nil] ++ Failure.success_fields(endpoint, :ocsp)

      endpoint
      |> endpoint_query()
      |> update(set: ^fields)
      |> Safe.unscoped()
      |> Safe.update_all([])
    end

    def record_error(endpoint, reason) do
      now = DateTime.utc_now()

      fields =
        [ocsp_checked_at: now, ocsp_error: to_message(reason)] ++
          Failure.error_fields(endpoint, reason, now)

      endpoint
      |> endpoint_query()
      |> update(set: ^fields)
      |> Safe.unscoped()
      |> Safe.update_all([])
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
