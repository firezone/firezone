defmodule PortalAPI.Client.DeviceTrust do
  @moduledoc """
  Device attestation from the client certificate presented at connect.

  Clients holding an MDM-provisioned certificate connect over mutual TLS to
  the dedicated `mtls_external_url` origin. Phoenix terminates the handshake, so
  TLS has already proven the client holds the certificate's private key. Bandit
  exposes the leaf certificate as part of the connection's peer data.

  A certificate is trusted when it allows TLS client authentication, permits
  digital signatures (Key Usage absent or including `digitalSignature`), is
  within its validity window, chains to one of the account's trust anchors,
  and its SANs yield at least one device identifier. Only the leaf arrives in
  the header, so any intermediate between it and the account's root has to be
  uploaded as a trust anchor too.

  Device identifiers come from SANs only: typed `firezone://<idtype>/<value>`
  URIs (with fallbacks for common MDM SAN conventions), normalized and
  screened against well-known garbage values before they ever reach an
  indexed column. A certificate without SAN-borne identifiers proves only
  that the holder has some certificate from the anchor CA, not which device
  it is, so it cannot attest anything.

  X.509 client authentication also reads typed SAN URIs. It requires an
  `account-id` and authenticates by `actor-id` when that claim is present,
  otherwise falling back to the actor's normalized email.

  Reaching the portal through that host is the client stating it has a
  certificate to present, so failing to prove one there is fatal to the
  connect rather than a silent downgrade. Connects that arrive anywhere else
  are simply unattested, and whether an unattested device may reach a given
  resource is a policy decision, not a socket one.
  """

  alias Portal.Authentication.{Credential, Subject}
  alias Portal.Crypto.X509
  alias __MODULE__.Database
  require Logger

  # Mirrors the trust anchor upload bound and caps synthetic peer data before
  # certificate decoding.
  @max_cert_bytes 16_384
  @max_chain_depth 4
  # Matches the varchar(255) device columns: the bulk session flush bypasses
  # changeset validation, so an oversized value would abort the whole batch.
  # This bound only protects the columns; garbage screening is the
  # blocklists' job.
  @max_identifier_bytes 255

  # Typed URI SAN idtypes: firezone://<idtype>/<value>
  @idtype_columns %{
    "serial" => :last_attested_device_serial,
    "apple-serial" => :last_attested_device_serial,
    "udid" => :last_attested_device_uuid,
    "apple-udid" => :last_attested_device_uuid,
    "smbios-uuid" => :last_attested_device_uuid,
    "intune-id" => :last_attested_mdm_device_id,
    "ws1-uuid" => :last_attested_mdm_device_id,
    "jamf-id" => :last_attested_mdm_device_id,
    "kandji-id" => :last_attested_mdm_device_id
  }

  @typed_uri_regex ~r{^firezone://([^/]+)/(.+)$}i
  # Authentication must distinguish an absent identity URI from a recognized
  # identity claim whose value is empty or invalid. The latter commits the
  # connection to X.509 authentication and must fail closed.
  @authentication_uri_regex ~r{^firezone://([^/]+)(?:/(.*))?$}i

  # Intune emits every SAN row as one comma-joined URI value. Splitting only
  # where a URI scheme follows keeps the comma inside
  # @microsoft_sid_uri_prefix intact, since a scheme cannot start with a digit.
  @joined_uri_regex ~r/,\s*(?=[a-zA-Z][a-zA-Z0-9+.\-]*:)/

  # Renewal artifacts that must never be treated as device identity.
  @microsoft_sid_uri_prefix "tag:microsoft.com,2022-09-14:sid:"

  # Well-known garbage serials stamped by OEMs into SMBIOS (lowercased).
  @serial_blocklist MapSet.new([
                      "to be filled by o.e.m.",
                      "to be filled by oem",
                      "default string",
                      "system serial number",
                      "none",
                      "n/a",
                      "not specified",
                      "not applicable",
                      "invalid",
                      "oem_serial",
                      "systemserialnumb",
                      "eval"
                    ])

  # All-zero / all-one / all-binary-digit runs are placeholders, not serials.
  @binary_run_regex ~r/^[01]+$/

  # One repeated character (FFFFFFFF) is a placeholder, not an identifier.
  @repeated_char_regex ~r/^(.)\1+$/

  # Serials and hardware GUIDs are printable ASCII; anything else is corrupt.
  @printable_ascii_regex ~r/^[\x20-\x7E]+$/

  # "idnotpresentbutsettable" is SMBIOS-speak for a UUID that was never set.
  @uuid_sentinels MapSet.new([
                    "00000000-0000-0000-0000-000000000000",
                    "ffffffff-ffff-ffff-ffff-ffffffffffff",
                    "03000200-0400-0500-0006-000700080009",
                    "idnotpresentbutsettable"
                  ])

  # Bare identifier shapes for the fallback paths.
  @classic_udid_regex ~r/^[0-9a-f]{40}$/i
  @modern_udid_regex ~r/^[0-9A-F]{8}-[0-9A-F]{16}$/i
  @guid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  @apple_serial_regex ~r/^[A-Z0-9]{8,14}$/i

  @type identifiers :: %{
          optional(:last_attested_mdm_device_id) => String.t(),
          optional(:last_attested_device_serial) => String.t(),
          optional(:last_attested_device_uuid) => String.t()
        }

  @type verified :: %{
          identifiers: identifiers(),
          last_attested_cert_serial: String.t(),
          last_attested_cert_fingerprint: String.t(),
          last_attested_cert_issuer: binary(),
          device: Portal.Device.t() | nil,
          matched_on: :mdm_device_id | :cert_identity | nil
        }

  @type prepared_authentication :: %{
          der: binary(),
          leaf: tuple(),
          account_id: Ecto.UUID.t(),
          identity: {:actor_id, Ecto.UUID.t()} | {:email, String.t()}
        }

  @type reason ::
          :not_x509_identity
          | :invalid_x509_identity
          | :x509_authentication_not_found
          | :x509_authentication_disabled
          | :x509_account_not_found
          | :x509_account_disabled
          | :x509_user_not_found
          | :x509_user_disabled
          | :x509_user_type_not_allowed
          | :x509_user_not_authorized
          | :not_attestation_host
          | :no_trust_anchors
          | :no_certificate_presented
          | :invalid_certificate
          | :missing_client_auth_eku
          | :missing_digital_signature_key_usage
          | :outside_validity_window
          | :untrusted_chain
          | :malformed_cert_serial
          | :malformed_cert_issuer
          | :no_device_identifiers
          | :certificate_revoked

  @doc """
  Decodes the bounded leaf certificate and extracts the X.509 authentication
  identity without touching the database or validating its chain.

  This intentionally cheap stage lets the socket rate-limit identity-bearing
  certificate attempts before any account, trust-anchor, or attestation work.
  """
  @spec prepare_authentication(map()) ::
          {:ok, prepared_authentication()} | {:error, reason()}
  def prepare_authentication(connect_info) do
    with :ok <- validate_attestation_host(connect_info),
         {:ok, der} <- presented_certificate(connect_info),
         {:ok, leaf} <- decode_leaf(der),
         {:ok, account_id, identity} <- extract_authentication_identity(leaf) do
      {:ok, %{der: der, leaf: leaf, account_id: account_id, identity: identity}}
    else
      {:error, reason}
      when reason in [:not_attestation_host, :no_certificate_presented, :not_x509_identity] ->
        {:error, :not_x509_identity}

      error ->
        error
    end
  end

  @doc """
  Authenticates a prepared X.509 identity after the socket has rate-limited it.

  The certificate chain is validated before the actor lookup, so an untrusted
  caller cannot use differing user lookup errors to enumerate active users.
  Once X.509 identity claims are found, identity and certificate validation
  failures must not downgrade to bearer authentication.
  """
  @spec authenticate(prepared_authentication(), Portal.Authentication.Context.t()) ::
          {:ok, Subject.t(), verified()} | {:error, reason()}
  def authenticate(
        %{der: der, leaf: leaf, account_id: account_id, identity: identity},
        context
      ) do
    with {:ok, account, auth_provider} <- Database.fetch_x509_account(account_id),
         {:ok, anchors} <- fetch_anchors(account.id),
         :ok <- validate_leaf(leaf, der, anchors),
         :ok <- ensure_account_enabled(account),
         {:ok, auth_provider} <- ensure_x509_authentication_enabled(auth_provider),
         {:ok, actor} <- Database.fetch_x509_actor(account, identity),
         %DateTime{} = certificate_expires_at <- X509.not_after(leaf),
         expires_at = %{
           certificate_expires_at
           | microsecond: {elem(certificate_expires_at.microsecond, 0), 6}
         },
         subject = %Subject{
           account: account,
           actor: actor,
           credential: %Credential{
             type: :x509,
             id: Ecto.UUID.generate(),
             auth_provider_id: auth_provider.id,
             scopes: nil
           },
           expires_at: expires_at,
           context: context
         },
         {:ok, proof} <- attest_validated(der, leaf, subject) do
      {:ok, subject, proof}
    else
      {:error, reason}
      when reason in [
             :x509_authentication_not_found,
             :x509_authentication_disabled,
             :x509_account_not_found,
             :x509_account_disabled,
             :x509_user_not_found,
             :x509_user_disabled,
             :x509_user_type_not_allowed
           ] ->
        Logger.info(
          "X.509 client authentication failed",
          [reason: reason, account_id: account_id] ++ authentication_identity_log(identity)
        )

        {:error, reason}

      nil ->
        {:error, :invalid_certificate}

      error ->
        error
    end
  end

  defp authentication_identity_log({:actor_id, actor_id}), do: [actor_id: actor_id]
  defp authentication_identity_log({:email, email}), do: [email: email]

  @doc false
  def revocation_endpoint_queue_opts do
    [
      name: :revocation_endpoint_queue,
      flush_interval: :timer.seconds(30),
      flush_threshold: 500,
      label: "revocation endpoint",
      on_flush: &flush_revocation_endpoints/1,
      dedup_key: &{&1.account_id, &1.issuer, &1.distribution_point}
    ]
  end

  @doc false
  def flush_revocation_endpoints(entries) do
    entries |> Enum.map(fn {attrs, _metadata} -> attrs end) |> Database.put_revocation_endpoints()
  end

  @doc """
  Attests the connecting device from the TLS peer certificate.

  `{:error, :not_attestation_host}` means the connect did not arrive on the
  mutual-TLS host, or no such host is configured, so there was nothing to
  attest. Every other error means the connect did arrive there and failed to
  prove a device identity, which the caller treats as fatal.
  """
  @spec attest(map(), Portal.Authentication.Subject.t()) ::
          {:ok, verified()} | {:error, reason()}
  def attest(connect_info, subject) do
    with :ok <- validate_attestation_host(connect_info),
         {:ok, der} <- presented_certificate(connect_info),
         {:ok, anchors} <- fetch_anchors(subject),
         {:ok, leaf} <- decode_leaf(der),
         :ok <- validate_leaf(leaf, der, anchors) do
      attest_validated(der, leaf, subject)
    end
  end

  defp attest_validated(der, leaf, subject) do
    with {:ok, serial} <- cert_serial(leaf),
         {:ok, issuer} <- cert_issuer(der),
         state = Database.attestation_state(issuer, serial, mdm_device_id(leaf), subject),
         :ok <- ensure_not_revoked(state, issuer, serial),
         {:ok, identifiers} <- device_identifiers(leaf) do
      learn_revocation_endpoint(state, issuer, leaf, subject)
      check_responder(state, issuer, serial, subject)

      {:ok,
       %{
         identifiers: identifiers,
         last_attested_cert_serial: serial,
         last_attested_cert_fingerprint: sha256_hex(der),
         last_attested_cert_issuer: issuer,
         device: state.device,
         matched_on: state.matched_on
       }}
    end
  end

  # Read ahead of the revocation check so both reach the database together, and
  # separately from the identifiers the caller gets: a certificate carrying none
  # is still worth checking for revocation, and refusing it belongs to that
  # check rather than to this one.
  defp mdm_device_id(leaf) do
    case device_identifiers(leaf) do
      {:ok, identifiers} -> Map.get(identifiers, :last_attested_mdm_device_id)
      {:error, _reason} -> nil
    end
  end

  ####################################
  ##### Certificate verification #####
  ####################################

  # Checked before anything touches the database: a connect on the plain API
  # origin never pays for the anchor lookup.
  defp validate_attestation_host(connect_info) do
    case attestation_origin() do
      nil -> {:error, :not_attestation_host}
      origin -> validate_origin(connect_info, origin)
    end
  end

  defp fetch_anchors(subject) do
    anchors =
      if Portal.Features.enabled?(:trust_anchors),
        do: Database.fetch_anchors(subject),
        else: []

    case anchors do
      [] -> {:error, :no_trust_anchors}
      anchors -> {:ok, anchors}
    end
  end

  defp ensure_account_enabled(%Portal.Account{is_disabled: false}), do: :ok
  defp ensure_account_enabled(%Portal.Account{is_disabled: true}), do: {:error, :x509_account_disabled}

  defp ensure_x509_authentication_enabled(nil),
    do: {:error, :x509_authentication_not_found}

  defp ensure_x509_authentication_enabled(%Portal.X509.AuthProvider{is_disabled: true}),
    do: {:error, :x509_authentication_disabled}

  defp ensure_x509_authentication_enabled(%Portal.X509.AuthProvider{is_disabled: false} = provider),
    do: {:ok, provider}

  defp presented_certificate(%{peer_data: %{ssl_cert: der}})
       when is_binary(der) and byte_size(der) > 0 and byte_size(der) <= @max_cert_bytes,
       do: {:ok, der}

  defp presented_certificate(%{peer_data: %{ssl_cert: der}}) when is_binary(der),
    do: {:error, :invalid_certificate}

  defp presented_certificate(_connect_info), do: {:error, :no_certificate_presented}

  defp attestation_origin do
    with url when is_binary(url) <- Portal.Config.get_env(:portal, :mtls_external_url),
         %URI{host: host, port: port} when is_binary(host) and is_integer(port) <- URI.parse(url) do
      {String.downcase(host), port}
    else
      _unconfigured -> nil
    end
  end

  defp validate_origin(
         %{uri: %URI{host: host, port: port}},
         {attestation_host, attestation_port}
       )
       when is_binary(host) and is_integer(port) do
    if {String.downcase(host), port} == {attestation_host, attestation_port} do
      :ok
    else
      {:error, :not_attestation_host}
    end
  end

  defp validate_origin(_connect_info, _attestation_origin), do: {:error, :not_attestation_host}

  defp decode_leaf(der) do
    case X509.decode_der_certificate(der, :otp) do
      {:ok, leaf} -> {:ok, leaf}
      {:error, :invalid} -> {:error, :invalid_certificate}
    end
  end

  defp validate_leaf(leaf, der, anchors) do
    cond do
      not X509.client_auth_eku?(leaf) ->
        {:error, :missing_client_auth_eku}

      not X509.digital_signature_allowed?(leaf) ->
        {:error, :missing_digital_signature_key_usage}

      not within_validity_window?(leaf) ->
        {:error, :outside_validity_window}

      true ->
        validate_chain(der, anchors)
    end
  end

  # Which anchor the chain happens to validate against says nothing about who
  # issued the leaf: an account holding both a root and its intermediate has two
  # anchors that can each validate the same certificate. The issuer is read off
  # the leaf itself instead, so only the outcome matters here.
  defp validate_chain(leaf_der, anchors) do
    anchor_ders = Enum.map(anchors, & &1.der)

    if Enum.any?(anchors, &chains_to?(leaf_der, &1.der, anchor_ders)) do
      :ok
    else
      {:error, :untrusted_chain}
    end
  end

  # The MDM device id anchors the certificate to the MDM's record of the device
  # and is the strongest identifier a certificate can carry, but not every MDM
  # can emit one (Mosyle exposes only a serial number variable), so it is not
  # required. A certificate asserting no identifier at all still fails: it
  # proves possession without proving what.
  defp device_identifiers(leaf) do
    case extract_identifiers(leaf) do
      empty when map_size(empty) == 0 -> {:error, :no_device_identifiers}
      identifiers -> {:ok, identifiers}
    end
  end

  # Checked against the cached CRL rather than fetched live: the CRL fetch job
  # owns the network call, so this stays a single indexed lookup. A CA that
  # publishes no CRL simply has no rows, and nothing is revoked.
  #
  # Keyed on the certificate's own issuer rather than on the anchor the chain
  # validated against. An account holding both a root and its intermediate has
  # two anchors that can each validate the same leaf, so the anchor does not
  # reliably say who issued it, and a serial means nothing without that.
  defp ensure_not_revoked(%{revoked?: true}, issuer, serial), do: refuse(issuer, serial)

  # Nothing for a responder to add where the issuer publishes a list: absence
  # from that list already means not revoked.
  defp ensure_not_revoked(%{crl_published?: true}, _issuer, _serial), do: :ok

  # Only consulted where the CA publishes no list, since a list covers every
  # device in one fetch and a responder is one request per certificate.
  defp ensure_not_revoked(%{ocsp_status: "revoked"}, issuer, serial), do: refuse(issuer, serial)

  # An answer we do not hold is not a refusal. The device proved possession of a
  # certificate that chains to an uploaded anchor, and turning it away because a
  # background job has not run yet would make a responder outage an outage for
  # the fleet. Nor is it worth saying anything about here: a certificate nobody
  # has asked about yet is what every first connect looks like, and whether a
  # CA's revocation data is actually arriving is recorded on its endpoint row by
  # the jobs that fetch it.
  defp ensure_not_revoked(_state, _issuer, _serial), do: :ok

  defp refuse(issuer, serial) do
    Logger.info("Refusing device certificate: revoked by its CA",
      issuer: X509.describe_name(issuer),
      cert_serial: serial
    )

    {:error, :certificate_revoked}
  end

  defp stale?(nil), do: true
  defp stale?(next_update), do: DateTime.compare(next_update, DateTime.utc_now()) != :gt

  # A CA advertises where its revocation lists live in the certificates it
  # issues, not in its own certificate, so a CA certificate names the list that
  # would revoke the CA. The list covering devices is named only by the leaves,
  # which is why the endpoint is learned here rather than at anchor upload.
  #
  # Asked about after the connect is already decided, so the answer lands for the
  # next one rather than holding this device at the door waiting on a responder.
  #
  # Skipped where the CA publishes a list, which covers the whole fleet in one
  # fetch and already answers for this certificate, and skipped again where the
  # cached answer is still current. What is left is the gap the scheduled run
  # cannot close on its own: a certificate nobody has asked about yet, because
  # it belongs to a device connecting for the first time.
  defp check_responder(%{crl_published?: true}, _issuer, _serial, _subject), do: :ok

  defp check_responder(%{ocsp_next_update: next_update}, issuer, serial, subject) do
    if stale?(next_update) do
      Portal.Ocsp.Sync.enqueue_check(subject.account.id, issuer, serial)
    end

    :ok
  end

  # Every address the certificate carries is kept, grouped as the certificate
  # groups them. A CA that partitions its revocations gives one certificate
  # several distribution points, and reading only one of them would miss every
  # revocation recorded in the others.
  defp learn_revocation_endpoint(state, issuer, leaf, subject) do
    crl_groups = leaf |> X509.crl_distribution_points() |> Enum.map(&order_by_scheme/1)
    ocsp_urls = leaf |> X509.authority_info_access() |> Map.fetch!(:ocsp) |> order_by_scheme()

    crl_groups
    |> endpoint_rows(ocsp_urls)
    |> Enum.reject(fn {point, _crl_urls, _ocsp_urls} -> point in state.known_points end)
    |> Enum.each(fn {point, crl_urls, row_ocsp_urls} ->
      enqueue_endpoint(issuer, point, crl_urls, row_ocsp_urls, subject)
    end)

    :ok
  end

  # Off the connect path. A certificate that partitions its list writes a row
  # per partition, and every connect rediscovers the same rows, so this is a
  # write that repeats forever and changes nothing after the first one.
  #
  # Losing a batch costs a scheduling round rather than a fetch: the next
  # connect on that certificate rediscovers the endpoint and enqueues it again.
  defp enqueue_endpoint(issuer, distribution_point, crl_urls, ocsp_urls, subject) do
    Portal.Queue.enqueue(:revocation_endpoint_queue, %{
      account_id: subject.account.id,
      issuer: issuer,
      distribution_point: distribution_point,
      crl_urls: crl_urls,
      ocsp_urls: ocsp_urls
    })

    :ok
  catch
    :exit, _reason -> :ok
  end

  # A certificate names one list per distribution point, so each becomes its own
  # row and syncs on its own. The addresses within one are alternates for the
  # same bytes, which is what lets a fetch stop at the first that answers.
  #
  # OCSP rides the first row only. It answers for the certificate rather than
  # for a partition, so repeating it would ask the same question once per list.
  defp endpoint_rows([], []), do: []

  defp endpoint_rows([], [first | _] = ocsp_urls), do: [{first, [], ocsp_urls}]

  defp endpoint_rows(crl_groups, ocsp_urls) do
    crl_groups
    |> Enum.with_index()
    |> Enum.map(fn
      {urls, 0} -> {List.first(urls), urls, ocsp_urls}
      {urls, _index} -> {List.first(urls), urls, []}
    end)
  end

  # HTTP first, since that is all the fetcher speaks. Anything else is kept
  # rather than dropped, so a CA publishing only over ldap is reported as a
  # scheme we cannot follow instead of looking like one that publishes nothing.
  defp order_by_scheme(urls) do
    Enum.sort_by(urls, &(not String.starts_with?(&1, ["http://", "https://"])))
  end

  defp cert_issuer(der) do
    case X509.issuer(der) do
      nil -> {:error, :malformed_cert_issuer}
      issuer -> {:ok, issuer}
    end
  end

  # A conforming serial is at most 20 octets (RFC 5280), so 255 hex characters
  # is already six times the largest legitimate value. A certificate past that
  # did not come from a working CA, and pinning one whose serial cannot be
  # recorded would leave the row describing a certificate it cannot identify.
  defp cert_serial(leaf) do
    serial = leaf |> X509.serial_number() |> Integer.to_string(16)

    if byte_size(serial) <= @max_identifier_bytes do
      {:ok, serial}
    else
      Logger.error("Refusing device certificate: serial number is not representable",
        serial_hex_length: byte_size(serial)
      )

      {:error, :malformed_cert_serial}
    end
  end

  defp within_validity_window?(leaf) do
    now = DateTime.utc_now()
    not_before = X509.not_before(leaf)
    not_after = X509.not_after(leaf)

    not is_nil(not_before) and not is_nil(not_after) and
      DateTime.compare(now, not_before) != :lt and DateTime.compare(now, not_after) != :gt
  end

  # Only the leaf is presented, so every certificate between it and the anchor
  # has to come from the account's uploaded anchors: admins may upload issuing
  # intermediates alongside (or instead of) roots.
  defp chains_to?(leaf_der, anchor_der, anchor_ders) do
    leaf_der
    |> candidate_chains(
      anchor_der,
      List.delete(anchor_ders, anchor_der),
      [leaf_der],
      @max_chain_depth
    )
    |> Enum.any?(fn chain ->
      match?({:ok, _result}, :public_key.pkix_path_validation(anchor_der, chain, []))
    end)
  rescue
    _error -> false
  end

  # Walks issuer links from the leaf up to the anchor, returning every
  # candidate chain in the trust order `:public_key.pkix_path_validation/3`
  # expects: the anchor's direct child first, the leaf last. `issued_by?`
  # compares names only, and renewed or cross-signed CAs share a subject DN,
  # so each ambiguous link is explored rather than committing to one issuer.
  defp candidate_chains(current_der, anchor_der, pool, acc, depth) when depth > 0 do
    direct = if issued_by?(current_der, anchor_der), do: [acc], else: []

    nested =
      for issuer_der <- pool,
          issued_by?(current_der, issuer_der),
          chain <-
            candidate_chains(
              issuer_der,
              anchor_der,
              List.delete(pool, issuer_der),
              [issuer_der | acc],
              depth - 1
            ) do
        chain
      end

    direct ++ nested
  end

  defp candidate_chains(_current, _anchor, _pool, _acc, _depth), do: []

  defp issued_by?(cert_der, issuer_der) do
    cert_der != issuer_der and :public_key.pkix_is_issuer(cert_der, issuer_der)
  rescue
    _error -> false
  end

  ####################################
  ##### Identifier extraction ########
  ####################################

  @doc """
  Extracts device identifiers from a trusted leaf certificate.

  Primary convention: one or more typed URI SANs (`firezone://serial/...`,
  `firezone://udid/...`, `firezone://intune-id/...`, ...), since a certificate
  should carry every identifier the MDM can assert. Intune emits these joined
  into a single comma-separated SAN value rather than one entry per row, so
  joined values are split back apart first. When no typed URI is present,
  falls back to bare recognized identifiers in URI SANs, then WS1-style
  `UDID=`/`SERIAL=` DNS SANs. The subject is never consulted:
  CN/OU values are profile-wide labels, not per-device identity. Values are
  normalized and screened per source, so a garbage value in one source never
  shadows a usable identifier in another; user identity fields
  (rfc822Name/UPN) are never consulted.
  """
  @spec extract_identifiers(tuple()) :: identifiers()
  def extract_identifiers(leaf) do
    uris =
      leaf
      |> X509.san_uris()
      |> Enum.flat_map(&split_joined_uris/1)
      |> Enum.reject(&String.starts_with?(&1, @microsoft_sid_uri_prefix))

    typed = extract_typed_uris(uris)

    if map_size(typed) > 0 do
      typed
    else
      fallback_identifiers(leaf, uris)
    end
  end

  @doc """
  Normalizes an extracted identifier value for its column, returning `nil`
  for empty or well-known garbage values (SMBIOS placeholder serials, UUID
  sentinels) so they never reach an indexed column.
  """
  @spec normalize_identifier(atom(), String.t()) :: String.t() | nil
  def normalize_identifier(column, value) when is_binary(value) do
    value = String.trim(value)

    cond do
      byte_size(value) > @max_identifier_bytes -> nil
      not Regex.match?(@printable_ascii_regex, value) -> nil
      column == :last_attested_device_serial -> normalize_serial(value)
      column == :last_attested_device_uuid -> normalize_uuid(value)
      column == :last_attested_mdm_device_id -> normalize_mdm_id(value)
      true -> nil
    end
  end

  def normalize_identifier(_column, _value), do: nil

  # Fallback ladder when no firezone:// typed URI is present: the first
  # extractor that yields a usable (post-normalization) identifier wins.
  defp fallback_identifiers(leaf, uris) do
    [
      fn -> extract_bare_uris(uris) end,
      fn -> extract_dns_identifiers(X509.san_dns_names(leaf)) end
    ]
    |> Enum.reduce_while(%{}, fn extract, _acc ->
      case extract.() do
        empty when map_size(empty) == 0 -> {:cont, %{}}
        found -> {:halt, found}
      end
    end)
  end

  defp extract_typed_uris(uris) do
    for uri <- uris,
        [_all, idtype, value] <- [Regex.run(@typed_uri_regex, uri)],
        column = Map.get(@idtype_columns, String.downcase(idtype)),
        not is_nil(column),
        reduce: %{} do
      acc -> put_normalized(acc, column, value)
    end
  end

  defp extract_bare_uris(uris) do
    for uri <- uris, {column, value} <- classify_bare(uri), reduce: %{} do
      acc -> put_normalized(acc, column, value)
    end
  end

  defp extract_dns_identifiers(dns_names) do
    for dns <- dns_names,
        name <- split_joined_dns_names(dns),
        {column, value} <- classify_dns(name),
        reduce: %{} do
      acc -> put_normalized(acc, column, value)
    end
  end

  defp split_joined_uris(uri), do: uri |> String.split(@joined_uri_regex) |> clean_parts()

  defp extract_authentication_identity(leaf) do
    claims =
      leaf
      |> X509.san_uris()
      |> Enum.flat_map(&split_joined_uris/1)
      |> Enum.reduce(
        %{
          account_ids: MapSet.new(),
          account_id_claim?: false,
          actor_ids: MapSet.new(),
          actor_id_claim?: false,
          emails: MapSet.new(),
          email_claim?: false
        },
        fn uri, claims ->
          case Regex.run(@authentication_uri_regex, uri) do
            [_all, idtype, value] -> put_authentication_claim(claims, idtype, value)
            [_all, idtype] -> put_authentication_claim(claims, idtype, "")
            nil -> claims
          end
        end
      )

    case {
      MapSet.to_list(claims.account_ids),
      MapSet.to_list(claims.actor_ids),
      MapSet.to_list(claims.emails),
      claims.account_id_claim?,
      claims.actor_id_claim?,
      claims.email_claim?
    } do
      {[], [], [], false, false, false} ->
        {:error, :not_x509_identity}

      {[account_id], [actor_id], _emails, true, true, _email_claim?} ->
        {:ok, account_id, {:actor_id, actor_id}}

      {[account_id], [], [email], true, false, true} ->
        {:ok, account_id, {:email, email}}

      {_account_ids, _actor_ids, _emails, _account_id_claim?, _actor_id_claim?, _email_claim?} ->
        {:error, :invalid_x509_identity}
    end
  end

  defp put_authentication_claim(claims, idtype, value) do
    case String.downcase(idtype) do
      "account-id" ->
        claims
        |> Map.put(:account_id_claim?, true)
        |> put_uuid_authentication_claim(:account_ids, value)

      "actor-id" ->
        claims
        |> Map.put(:actor_id_claim?, true)
        |> put_uuid_authentication_claim(:actor_ids, value)

      "email" ->
        claims
        |> Map.put(:email_claim?, true)
        |> put_email_authentication_claim(value)

      _idtype ->
        claims
    end
  end

  defp put_uuid_authentication_claim(claims, key, value) do
    with {:ok, value} <- decode_uri_component(value),
         {:ok, id} <- Ecto.UUID.cast(String.trim(value)) do
      Map.update!(claims, key, &MapSet.put(&1, id))
    else
      _error -> claims
    end
  end

  defp put_email_authentication_claim(claims, value) do
    with {:ok, email} <- decode_uri_component(value),
         {:ok, email} when email != "" <- Portal.Email.normalize_for_match(email) do
      update_in(claims.emails, &MapSet.put(&1, email))
    else
      _error -> claims
    end
  end

  defp decode_uri_component(value) do
    {:ok, URI.decode(value)}
  rescue
    ArgumentError -> {:error, :invalid}
  end

  # A comma is never valid in a hostname, so joined DNS SANs split plainly.
  defp split_joined_dns_names(dns_name), do: dns_name |> String.split(",") |> clean_parts()

  defp clean_parts(parts), do: parts |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp put_normalized(acc, column, value) do
    case normalize_identifier(column, value) do
      nil -> acc
      normalized -> Map.put_new(acc, column, normalized)
    end
  end

  defp classify_dns(dns_name) do
    case Regex.run(~r/^(UDID|SERIAL)=(.+)$/i, dns_name) do
      [_all, kind, value] ->
        case String.upcase(kind) do
          "UDID" -> [{:last_attested_device_uuid, value}]
          "SERIAL" -> [{:last_attested_device_serial, value}]
        end

      nil ->
        []
    end
  end

  # Bare GUIDs from URI SANs are MDM cloud device ids (e.g. Intune
  # {{DeviceId}}); typed URIs are the recommended way to disambiguate.
  defp classify_bare(value) do
    value = String.trim(value)

    cond do
      Regex.match?(@classic_udid_regex, value) -> [{:last_attested_device_uuid, value}]
      Regex.match?(@modern_udid_regex, value) -> [{:last_attested_device_uuid, value}]
      Regex.match?(@guid_regex, value) -> [{:last_attested_mdm_device_id, value}]
      Regex.match?(@apple_serial_regex, value) -> [{:last_attested_device_serial, value}]
      true -> []
    end
  end

  defp normalize_serial(value) do
    if MapSet.member?(@serial_blocklist, String.downcase(value)) or
         Regex.match?(@binary_run_regex, value) or
         Regex.match?(@repeated_char_regex, value) do
      nil
    else
      String.upcase(value)
    end
  end

  defp normalize_uuid(value) do
    normalized =
      if Regex.match?(@modern_udid_regex, value) do
        # 25-char ChipID-ECID UDIDs keep their hyphen and casing convention.
        String.upcase(value)
      else
        String.downcase(value)
      end

    if MapSet.member?(@uuid_sentinels, String.downcase(normalized)) or
         Regex.match?(@binary_run_regex, normalized) or
         Regex.match?(@repeated_char_regex, normalized) do
      nil
    else
      normalized
    end
  end

  # MDM ids may be small numeric values (Jamf device ids), so the
  # placeholder-run screens for serials/UUIDs do not apply; a bare "0" is
  # still a placeholder (Jamf ids start at 1).
  defp normalize_mdm_id("0"), do: nil

  defp normalize_mdm_id(value) do
    normalized = String.downcase(value)

    if MapSet.member?(@uuid_sentinels, normalized) do
      nil
    else
      normalized
    end
  end

  defp sha256_hex(der), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

  defmodule Database do
    @moduledoc false
    import Ecto.Query
    alias Portal.Crypto.X509
    alias Portal.Safe

    def fetch_x509_account(account_id) do
      query =
        from(account in Portal.Account,
          left_join: auth_provider in Portal.X509.AuthProvider,
          on: auth_provider.account_id == account.id,
          where: account.id == ^account_id,
          select: %{
            account: account,
            auth_provider: auth_provider
          }
        )

      case query |> Safe.unscoped() |> Safe.one() do
        nil ->
          {:error, :x509_account_not_found}

        %{account: %Portal.Account{} = account, auth_provider: auth_provider} ->
          {:ok, account, auth_provider}
      end
    end

    def fetch_x509_actor(account, {:actor_id, actor_id}) do
      query =
        from(actor in Portal.Actor,
          where: actor.account_id == ^account.id and actor.id == ^actor_id
        )

      authorize_x509_actor(query, [:account_user, :account_admin_user, :service_account])
    end

    def fetch_x509_actor(account, {:email, email}) do
      query =
        from(actor in Portal.Actor,
          where: actor.account_id == ^account.id and actor.email == ^email
        )

      authorize_x509_actor(query, [:account_user, :account_admin_user])
    end

    defp authorize_x509_actor(query, allowed_types) do
      case query |> Safe.unscoped() |> Safe.one() do
        nil ->
          {:error, :x509_user_not_found}

        %Portal.Actor{is_disabled: true} ->
          {:error, :x509_user_disabled}

        %Portal.Actor{is_disabled: false, type: type} = actor ->
          if type in allowed_types,
            do: {:ok, actor},
            else: {:error, :x509_user_type_not_allowed}

        _user_type_not_allowed ->
          {:error, :x509_user_type_not_allowed}
      end
    end

    # A refused read leaves the connect with no facts rather than with false
    # ones, which the caller treats the same way it treats a certificate no
    # table has heard of.
    @empty_state %{
      revoked?: false,
      crl_published?: false,
      known_points: [],
      ocsp_status: nil,
      ocsp_next_update: nil,
      device: nil,
      matched_on: nil
    }

    # Everything the connect needs to decide about this certificate, in one
    # round trip: whether a list revoked it, whether its issuer publishes a
    # list we can actually fetch, what its responder last said, and which
    # device row it belongs to. Read apart they also raced each other, so an
    # endpoint appearing between the coverage check and the responder read
    # could make the connect ignore an answer it had just decided to trust.
    #
    # The account is the base because it is the one row guaranteed to exist,
    # which keeps the outer joins from dropping the result when a certificate
    # is unknown to every one of these tables.
    def attestation_state(issuer, serial, mdm_device_id, subject) do
      actor_id = subject.actor.id

      from(a in Portal.Account,
        left_join: r in Portal.CrlRevocation,
        on: r.account_id == a.id and r.issuer == ^issuer and r.serial == ^serial,
        left_join: s in Portal.OcspStatus,
        on: s.account_id == a.id and s.issuer == ^issuer and s.serial == ^serial,
        left_join: d in Portal.Device,
        on:
          d.account_id == a.id and d.actor_id == ^actor_id and d.type == :client and
            (fragment("? = ?", d.last_attested_mdm_device_id, ^mdm_device_id) or
               (d.last_attested_cert_issuer == ^issuer and
                  d.last_attested_cert_serial == ^serial)),
        order_by: [
          asc:
            fragment(
              "CASE WHEN ? = ? THEN 0 ELSE 1 END",
              d.last_attested_mdm_device_id,
              ^mdm_device_id
            )
        ],
        limit: 1,
        select: %{
          revoked?: not is_nil(r.serial),
          crl_published?:
            fragment(
              """
              EXISTS (
                SELECT 1 FROM revocation_endpoints e
                WHERE e.account_id = ? AND e.issuer = ?
                AND EXISTS (
                  SELECT 1 FROM unnest(e.crl_urls) AS u
                  WHERE u LIKE 'http://%' OR u LIKE 'https://%'
                )
              )
              """,
              a.id,
              ^issuer
            ),
          known_points:
            fragment(
              """
              ARRAY(
                SELECT distribution_point FROM revocation_endpoints e
                WHERE e.account_id = ? AND e.issuer = ?
              )
              """,
              a.id,
              ^issuer
            ),
          ocsp_status: s.status,
          ocsp_next_update: s.next_update,
          device: d
        }
      )
      |> Safe.scoped(subject)
      |> Safe.one()
      |> normalize_state(mdm_device_id)
    end

    # Unscoped with the account pinned explicitly rather than scoped to the
    # subject: this is bookkeeping the connect happens to discover, and a client
    # has no business holding write rights on its account's revocation settings
    # just to record it.
    #
    # Inserted once per issuer and left alone afterwards, so a later connect
    # never overwrites what the fetch job has since recorded, nor an address an
    # administrator corrected by hand.
    def put_revocation_endpoints(attrs_list) do
      rows =
        attrs_list
        |> Enum.uniq_by(&{&1.account_id, &1.issuer, &1.distribution_point})
        |> Enum.flat_map(&build_row/1)

      case rows do
        [] ->
          0

        rows ->
          {count, _returned} =
            Safe.unscoped()
            |> Safe.insert_all(Portal.RevocationEndpoint, rows, on_conflict: :nothing)

          count
      end
    end

    # Validated before insert rather than after, so a certificate advertising an
    # address too long to record leaves the endpoint unlearned instead of taking
    # the rest of the batch down with it.
    defp build_row(attrs) do
      now = DateTime.utc_now()

      changeset =
        %Portal.RevocationEndpoint{}
        |> Ecto.Changeset.change(Map.merge(attrs, %{inserted_at: now, updated_at: now}))
        |> Portal.RevocationEndpoint.changeset()

      case Ecto.Changeset.apply_action(changeset, :insert) do
        {:ok, endpoint} -> [Map.take(endpoint, Portal.RevocationEndpoint.__schema__(:fields))]
        {:error, _changeset} -> []
      end
    end

    def fetch_anchors(%Portal.Authentication.Subject{} = subject) do
      from(c in Portal.TrustAnchorCertificate,
        select: %{id: c.id, pem: c.pem}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> decode_anchors()
    end

    def fetch_anchors(account_id) when is_binary(account_id) do
      from(c in Portal.TrustAnchorCertificate,
        where: c.account_id == ^account_id,
        select: %{id: c.id, pem: c.pem}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> decode_anchors()
    end

    defp decode_anchors(certificates) do
      certificates
      |> Enum.flat_map(&decode_anchor_pem/1)
      |> Enum.uniq_by(& &1.der)
    end

    # One uploaded anchor may hold several certificates, so each DER carries the
    # row it came from.
    defp decode_anchor_pem(%{id: id, pem: pem}) do
      case X509.pem_decode(pem) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&X509.certificate_entry?/1)
          |> Enum.map(fn {_type, der, _info} -> %{id: id, der: der} end)

        {:error, _reason} ->
          []
      end
    end

    # An outer join that matched nothing still fills the struct, with every
    # field nil, so the primary key is what says whether there was a row.
    defp normalize_state(%{device: %Portal.Device{id: id} = device} = state, mdm_device_id)
         when not is_nil(id) do
      Map.put(state, :matched_on, matched_on(device, mdm_device_id))
    end

    defp normalize_state(%{} = state, _mdm_device_id) do
      state |> Map.put(:device, nil) |> Map.put(:matched_on, nil)
    end

    defp normalize_state(_other, _mdm_device_id), do: @empty_state

    # The MDM device id is assigned by the MDM service rather than reported by
    # the device, so it is the only identifier a device cannot choose for
    # itself and the row it names wins. A certificate carrying none resolves by
    # the certificate itself, which lasts exactly as long as the certificate.
    defp matched_on(device, mdm_device_id) do
      if not is_nil(mdm_device_id) and device.last_attested_mdm_device_id == mdm_device_id do
        :mdm_device_id
      else
        :cert_identity
      end
    end
  end
end
