defmodule PortalAPI.Client.DeviceTrust do
  @moduledoc """
  Device-trust challenge for `/client/v3` sockets.

  After a v3 channel join on a gated account, the portal pushes a 32-byte
  nonce; the client answers with one or more MDM-provisioned certificates and
  a signature over the nonce. A response entry is trusted when its leaf allows
  TLS client authentication, permits digital signatures (Key Usage absent or
  including `digitalSignature`), is within its validity window, chains to one
  of the account's trust anchors, its key verifies the signature, and its
  SANs yield at least one device identifier.

  Device identifiers come from SANs only: typed `firezone://<idtype>/<value>`
  URIs (with fallbacks for common MDM SAN conventions), normalized and
  screened against well-known garbage values before they ever reach an
  indexed column. A certificate without SAN-borne identifiers proves only
  that the holder has some certificate from the anchor CA, not which device
  it is, so it cannot attest anything.

  Failure never blocks the connection: the caller falls back to the plain
  `firezone_id` resolution path.
  """

  alias Portal.Crypto.X509
  alias __MODULE__.Database
  require Logger

  @nonce_bytes 32
  @subject_cn "dev.firezone.device-trust"
  @max_entries 8
  @max_certs_per_entry 4
  @max_cert_bytes 16_384
  @max_signature_bytes 1_024
  @max_chain_depth 4

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
          last_attested_cert_serial: String.t(),
          last_attested_cert_fingerprint: String.t()
        }

  @doc "Generates a fresh challenge nonce."
  @spec nonce() :: binary()
  def nonce, do: :crypto.strong_rand_bytes(@nonce_bytes)

  @doc "The payload pushed to the client with the `device_trust_request` event."
  @spec challenge_payload(binary()) :: map()
  def challenge_payload(nonce) when is_binary(nonce) do
    %{nonce: Base.encode64(nonce), subject_cn: @subject_cn}
  end

  @doc """
  Fetches the account's trust anchor certificates in a single query that also
  applies the global `trust_anchors` feature flag: an empty result means the
  device-trust challenge is disabled for this account (flag off, or no
  anchors uploaded). A non-empty result doubles as the connect-time gate and
  the verification material for the challenge response, so the response
  never needs a second fetch.
  """
  @spec fetch_enabled_anchors(Portal.Authentication.Subject.t()) :: [
          %{der: binary(), fingerprint: String.t()}
        ]
  def fetch_enabled_anchors(subject) do
    Database.fetch_enabled_anchors(subject)
  end

  @doc """
  Verifies a `device_trust_response` payload against the challenge nonce and
  the trust anchors fetched at connect time.

  Returns `{:ok, verified}` for the first trusted entry,
  `{:error, :verification_failed}` when at least one entry carried a real
  certificate that failed validation (admin misconfiguration signal), and
  `{:error, :no_usable_cert}` when no entry contained a usable certificate
  (unenrolled device).
  """
  @spec verify_response(term(), binary(), [%{der: binary(), fingerprint: String.t()}]) ::
          {:ok, verified()} | {:error, :verification_failed | :no_usable_cert}
  def verify_response(entries, nonce, anchors) when is_list(entries) and is_binary(nonce) do
    entries
    |> Enum.take(@max_entries)
    |> Enum.reduce_while({:error, :no_usable_cert}, fn entry, acc ->
      case verify_entry(entry, nonce, anchors) do
        {:ok, verified} ->
          {:halt, {:ok, verified}}

        {:error, :invalid_entry} ->
          {:cont, acc}

        {:error, reason} ->
          Logger.debug("Device trust response entry failed verification", reason: reason)

          {:cont, {:error, :verification_failed}}
      end
    end)
  end

  def verify_response(_entries, _nonce, _anchors), do: {:error, :no_usable_cert}

  ####################################
  ##### Entry verification ###########
  ####################################

  defp verify_entry(entry, nonce, anchors) when is_map(entry) do
    with {:ok, [leaf_der | intermediate_ders]} <- decode_certs(entry),
         {:ok, signature} <- decode_base64(entry["signed_challenge"], @max_signature_bytes),
         {:ok, leaf_otp} <- X509.decode_der_certificate(leaf_der, :otp) do
      cond do
        not X509.client_auth_eku?(leaf_otp) ->
          {:error, :missing_client_auth_eku}

        not X509.digital_signature_allowed?(leaf_otp) ->
          {:error, :missing_digital_signature_key_usage}

        not within_validity_window?(leaf_otp) ->
          {:error, :outside_validity_window}

        not chain_valid?(leaf_der, intermediate_ders, anchors) ->
          {:error, :untrusted_chain}

        not signature_valid?(nonce, signature, leaf_otp) ->
          {:error, :invalid_signature}

        true ->
          verified_result(leaf_der, leaf_otp)
      end
    else
      _other -> {:error, :invalid_entry}
    end
  end

  defp verify_entry(_entry, _nonce, _anchors), do: {:error, :invalid_entry}

  defp verified_result(leaf_der, leaf_otp) do
    case extract_identifiers(leaf_otp) do
      identifiers when map_size(identifiers) == 0 ->
        {:error, :no_device_identifiers}

      identifiers ->
        {:ok,
         %{
           identifiers: identifiers,
           last_attested_cert_serial: leaf_otp |> X509.serial_number() |> Integer.to_string(16),
           last_attested_cert_fingerprint: sha256_hex(leaf_der)
         }}
    end
  end

  # Accepts the flexible `"certs"` list (leaf first, optional intermediates)
  # as well as the single-cert `"cert"` shape.
  defp decode_certs(%{"certs" => certs}) when is_list(certs) and certs != [] do
    certs
    |> Enum.take(@max_certs_per_entry)
    |> Enum.reduce_while({:ok, []}, fn cert_b64, {:ok, acc} ->
      case decode_base64(cert_b64, @max_cert_bytes) do
        {:ok, der} -> {:cont, {:ok, [der | acc]}}
        _other -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ders} -> {:ok, Enum.reverse(ders)}
      :error -> :error
    end
  end

  defp decode_certs(%{"cert" => cert_b64}) when is_binary(cert_b64) do
    decode_certs(%{"certs" => [cert_b64]})
  end

  defp decode_certs(_entry), do: :error

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

  defp within_validity_window?(leaf_otp) do
    now = DateTime.utc_now()
    not_before = X509.not_before(leaf_otp)
    not_after = X509.not_after(leaf_otp)

    not is_nil(not_before) and not is_nil(not_after) and
      DateTime.compare(now, not_before) != :lt and DateTime.compare(now, not_after) != :gt
  end

  # The candidate chain is assembled from certificates supplied by the device
  # and/or uploaded to the portal as trust anchors: clients often cannot choose
  # which certificates they find and send, and admins may upload issuing
  # intermediates alongside (or instead of) roots.
  defp chain_valid?(leaf_der, intermediate_ders, anchors) do
    anchor_ders = Enum.map(anchors, & &1.der)
    pool = Enum.uniq(intermediate_ders ++ anchor_ders)

    Enum.any?(anchor_ders, fn anchor_der ->
      leaf_der
      |> candidate_chains(anchor_der, List.delete(pool, anchor_der), [leaf_der], @max_chain_depth)
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

  defp signature_valid?(nonce, signature, leaf_otp) do
    case X509.subject_public_key(leaf_otp) do
      {:ok, public_key} ->
        :public_key.verify(nonce, X509.verification_digest(leaf_otp), signature, public_key)

      :error ->
        false
    end
  rescue
    _error -> false
  end

  ####################################
  ##### Identifier extraction ########
  ####################################

  @doc """
  Extracts device identifiers from a verified leaf certificate.

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
  def extract_identifiers(leaf_otp) do
    uris =
      leaf_otp
      |> X509.san_uris()
      |> Enum.reject(&String.starts_with?(&1, @microsoft_sid_uri_prefix))

    typed = extract_typed_uris(uris)

    if map_size(typed) > 0 do
      typed
    else
      fallback_identifiers(leaf_otp, uris)
    end
  end

  # Fallback ladder when no firezone:// typed URI is present: the first
  # extractor that yields a usable (post-normalization) identifier wins.
  defp fallback_identifiers(leaf_otp, uris) do
    [
      fn -> extract_bare_uris(uris) end,
      fn -> extract_dns_identifiers(X509.san_dns_names(leaf_otp)) end
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

  @doc """
  Normalizes an extracted identifier value for its column, returning `nil`
  for empty or well-known garbage values (SMBIOS placeholder serials, UUID
  sentinels) so they never reach an indexed column.
  """
  @spec normalize_identifier(atom(), String.t()) :: String.t() | nil
  def normalize_identifier(column, value) when is_binary(value) do
    value = String.trim(value)

    cond do
      not Regex.match?(@printable_ascii_regex, value) -> nil
      column == :last_attested_device_serial -> normalize_serial(value)
      column == :last_attested_device_uuid -> normalize_uuid(value)
      column == :last_attested_mdm_device_id -> normalize_mdm_id(value)
      true -> nil
    end
  end

  def normalize_identifier(_column, _value), do: nil

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
      |> Safe.scoped(subject, :replica)
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
