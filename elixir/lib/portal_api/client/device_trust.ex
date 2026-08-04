defmodule PortalAPI.Client.DeviceTrust do
  @moduledoc """
  Device attestation from the client certificate presented at connect.

  Accounts with trust anchors uploaded require their clients to connect over
  mutual TLS to the dedicated `x509_external_url` host. The load balancer
  terminates the handshake, so TLS has already proven the client holds the
  certificate's private key, and passes the leaf up as base64-encoded DER in
  the `x-client-cert` header.

  The header is honored only on that host, and the load balancer must strip
  any inbound `x-client-cert` and `x-forwarded-host` on every host it serves:
  a request that can set either header can claim any device identity.

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

  Attestation is required rather than advisory: once an account has trust
  anchors, a connect that cannot produce a trusted certificate is refused.
  """

  alias Portal.Crypto.X509
  alias __MODULE__.Database

  # Mirrors the trust anchor upload bound. Bandit rejects any header over
  # 10_000 bytes on the wire first, so a certificate large enough to reach
  # this bound never gets here.
  @max_cert_bytes 16_384
  @max_chain_depth 4
  @certificate_header "x-client-cert"

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
    "entra-id" => :last_attested_mdm_device_id,
    "ws1-uuid" => :last_attested_mdm_device_id,
    "jamf-id" => :last_attested_mdm_device_id,
    "kandji-id" => :last_attested_mdm_device_id
  }

  @typed_uri_regex ~r{^firezone://([^/]+)/(.+)$}i

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
          optional(:last_attested_device_serial) => String.t(),
          optional(:last_attested_device_uuid) => String.t(),
          optional(:last_attested_mdm_device_id) => String.t()
        }

  @type verified :: %{
          identifiers: identifiers(),
          last_attested_cert_serial: String.t() | nil,
          last_attested_cert_fingerprint: String.t()
        }

  @type reason ::
          :untrusted_host
          | :no_certificate_presented
          | :invalid_certificate
          | :missing_client_auth_eku
          | :missing_digital_signature_key_usage
          | :outside_validity_window
          | :untrusted_chain
          | :no_device_identifiers

  @doc """
  Attests the connecting device from the certificate the load balancer passed
  up.

  Returns `{:ok, nil}` when the account is not gated: no attestation host is
  configured, the global `trust_anchors` feature is off, or the account has
  uploaded no anchors. Returns `{:ok, verified}` when the presented
  certificate is trusted, and `{:error, reason}` when the account is gated
  and it is not.
  """
  @spec attest(map(), Portal.Authentication.Subject.t()) ::
          {:ok, verified() | nil} | {:error, reason()}
  def attest(connect_info, subject) do
    with host when is_binary(host) <- attestation_host(),
         [_anchor | _rest] = anchors <- Database.fetch_enabled_anchors(subject) do
      verify_certificate(connect_info, host, anchors)
    else
      _not_gated -> {:ok, nil}
    end
  end

  ####################################
  ##### Certificate verification #####
  ####################################

  defp verify_certificate(connect_info, host, anchors) do
    with {:ok, der} <- presented_certificate(connect_info, host),
         {:ok, leaf} <- decode_leaf(der),
         :ok <- validate_leaf(leaf, der, anchors),
         {:ok, identifiers} <- device_identifiers(leaf) do
      {:ok,
       %{
         identifiers: identifiers,
         last_attested_cert_serial: format_cert_serial(leaf),
         last_attested_cert_fingerprint: sha256_hex(der)
       }}
    end
  end

  defp presented_certificate(connect_info, host) do
    with :ok <- validate_host(connect_info, host),
         {:ok, encoded} <- fetch_certificate_header(connect_info) do
      decode_certificate(encoded)
    end
  end

  defp attestation_host do
    with url when is_binary(url) <- Portal.Config.get_env(:portal, :x509_external_url),
         %URI{host: host} when is_binary(host) <- URI.parse(url) do
      String.downcase(host)
    else
      _unconfigured -> nil
    end
  end

  defp validate_host(%{uri: %URI{host: host}}, attestation_host) when is_binary(host) do
    if String.downcase(host) == attestation_host do
      :ok
    else
      {:error, :untrusted_host}
    end
  end

  defp validate_host(_connect_info, _attestation_host), do: {:error, :untrusted_host}

  # The load balancer sets the header to an empty value when the handshake
  # carried no client certificate.
  defp fetch_certificate_header(%{x_headers: x_headers}) when is_list(x_headers) do
    case List.keyfind(x_headers, @certificate_header, 0) do
      {@certificate_header, encoded} when is_binary(encoded) and encoded != "" -> {:ok, encoded}
      _other -> {:error, :no_certificate_presented}
    end
  end

  defp fetch_certificate_header(_connect_info), do: {:error, :no_certificate_presented}

  defp decode_certificate(encoded) do
    case decode_base64(encoded, @max_cert_bytes) do
      {:ok, der} -> {:ok, der}
      :error -> {:error, :invalid_certificate}
    end
  end

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

      not chain_valid?(der, anchors) ->
        {:error, :untrusted_chain}

      true ->
        :ok
    end
  end

  defp device_identifiers(leaf) do
    case extract_identifiers(leaf) do
      empty when map_size(empty) == 0 -> {:error, :no_device_identifiers}
      identifiers -> {:ok, identifiers}
    end
  end

  # A conforming serial is at most 20 octets (RFC 5280), but the column is
  # the real bound: a serial that cannot fit varchar(255) is dropped rather
  # than aborting the bulk session flush. The fingerprint remains the pin.
  defp format_cert_serial(leaf) do
    serial = leaf |> X509.serial_number() |> Integer.to_string(16)

    if byte_size(serial) <= @max_identifier_bytes do
      serial
    else
      nil
    end
  end

  # Bound the encoded input before decoding: base64 is 4 characters per 3 bytes.
  defp decode_base64(value, max_decoded_bytes)
       when is_binary(value) and byte_size(value) <= div(max_decoded_bytes + 2, 3) * 4 do
    case Base.decode64(value) do
      {:ok, decoded} when decoded != "" and byte_size(decoded) <= max_decoded_bytes ->
        {:ok, decoded}

      _other ->
        :error
    end
  end

  defp decode_base64(_value, _max_decoded_bytes), do: :error

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
  defp chain_valid?(leaf_der, anchors) do
    anchor_ders = Enum.map(anchors, & &1.der)

    Enum.any?(anchor_ders, fn anchor_der ->
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
  `firezone://udid/...`, `firezone://intune-id/...`, ...) — a certificate
  should carry every identifier the MDM can assert. When no typed URI is
  present, falls back to bare recognized identifiers in URI SANs, then
  WS1-style `UDID=`/`SERIAL=` DNS SANs. The subject is never consulted:
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
    for dns <- dns_names, {column, value} <- classify_dns(dns), reduce: %{} do
      acc -> put_normalized(acc, column, value)
    end
  end

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

    # One round trip: the join on the global feature-flag row makes the query
    # return no anchors at all when the flag is off, so the caller's gate
    # check and verification material come from the same query.
    def fetch_enabled_anchors(subject) do
      from(c in Portal.TrustAnchorCertificate,
        # The features table is global per-deployment state with no account_id.
        # credo:disable-for-next-line Credo.Check.Warning.MissingAccountIdInJoin
        join: f in Portal.Features,
        on: f.feature == :trust_anchors and f.enabled == true,
        select: c.pem
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Enum.flat_map(&decode_anchor_pem/1)
      |> Enum.uniq()
      |> Enum.map(fn der ->
        %{der: der, fingerprint: Base.encode16(:crypto.hash(:sha256, der), case: :lower)}
      end)
    end

    defp decode_anchor_pem(pem) do
      case X509.pem_decode(pem) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&X509.certificate_entry?/1)
          |> Enum.map(fn {_type, der, _info} -> der end)

        {:error, _reason} ->
          []
      end
    end
  end
end
