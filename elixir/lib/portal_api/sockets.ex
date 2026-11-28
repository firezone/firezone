defmodule PortalAPI.Sockets do
  @moduledoc """
  This module provides a set of helper function for Phoenix sockets and
  error handling around them.
  """
  require Logger

  alias PortalAPI.ProblemDetails
  alias __MODULE__.Database

  @x509_rejection_details %{
    invalid_certificate:
      "The client certificate is malformed or exceeds the supported size limit.",
    invalid_x509_identity:
      "The client certificate contains invalid or incomplete X.509 user identity claims.",
    malformed_cert_issuer: "The client certificate contains a malformed issuer.",
    malformed_cert_serial: "The client certificate contains a malformed serial number.",
    missing_client_auth_eku:
      "The client certificate is not valid for TLS client authentication.",
    missing_digital_signature_key_usage:
      "The client certificate does not permit digital signatures.",
    no_device_identifiers:
      "The client certificate does not contain a supported device identifier.",
    no_trust_anchors:
      "The Firezone account identified by the client certificate has no trust anchors configured.",
    outside_validity_window: "The client certificate is expired or not yet valid.",
    untrusted_chain:
      "The client certificate was not issued by a certificate authority trusted by this Firezone account.",
    x509_account_disabled: "The Firezone account identified by the client certificate is disabled.",
    x509_account_not_found:
      "The client certificate identifies a Firezone account that does not exist.",
    x509_authentication_disabled:
      "X.509 user authentication is disabled for the Firezone account identified by the client certificate.",
    x509_authentication_not_found:
      "X.509 user authentication is not configured for the Firezone account identified by the client certificate.",
    x509_user_disabled: "The user identified by the client certificate is disabled.",
    x509_user_not_found:
      "The client certificate identifies a user that does not exist in the identified Firezone account.",
    x509_user_type_not_allowed:
      "The user identified by the client certificate cannot authenticate using X.509."
  }

  # Versions that retry a 429 (#11594). Older ones stop for good on a 429, so
  # they get a 503 instead. Relays always run a current build.
  @retries_on_429_since %{
    "apple-client" => "1.5.20",
    "android-client" => "1.5.9",
    "gui-client" => "1.5.10",
    "headless-client" => "1.5.6",
    "gateway" => "1.5.0",
    "relay" => "0.0.0"
  }

  @doc """
  Extracts the token from connection parameters or headers.

  Checks the `x-authorization` header first (expecting "Bearer {token}" format),
  then falls back to the `token` query parameter.

  Returns `{:ok, token}` if found, or `{:error, :missing_token}` if no token is present.
  """
  def extract_token(params, connect_info) do
    with {:error, :missing_token} <- extract_token_from_header(connect_info) do
      extract_token_from_params(params)
    end
  end

  def handle_error(conn, :invalid_token),
    do: ProblemDetails.send_with_code(conn, 401, :invalid_token, "Invalid token")

  def handle_error(conn, :missing_token),
    do: ProblemDetails.send_with_code(conn, 401, :missing_token, "Missing token")

  def handle_error(conn, :limits_exceeded),
    do:
      ProblemDetails.send_with_code(
        conn,
        402,
        :limits_exceeded,
        "This account is temporarily suspended from client authentication " <>
          "due to exceeding billing limits. Please contact your administrator to add more seats."
      )

  def handle_error(conn, :connected_devices_limit_reached),
    do:
      ProblemDetails.send_with_code(
        conn,
        403,
        :connected_devices_limit_reached,
        "This user has reached the number of devices that can be connected at the same time. " <>
          "Disconnect another device and try again."
      )

  def handle_error(conn, :account_disabled),
    do: ProblemDetails.send_with_code(conn, 403, :account_disabled, "The account is disabled")

  def handle_error(conn, :unauthenticated),
    do: ProblemDetails.send_with_code(conn, 403, :unauthenticated, "Forbidden")

  def handle_error(conn, :device_untrusted),
    do:
      ProblemDetails.send_with_code(
        conn,
        403,
        :device_untrusted,
        "This device did not present a valid certificate from a certificate authority " <>
          "your organization trusts. Please contact your administrator."
      )

  def handle_error(conn, :certificate_revoked),
    do:
      ProblemDetails.send_with_code(
        conn,
        403,
        :certificate_revoked,
        "This device's certificate has been revoked by your organization's certificate " <>
          "authority. Please contact your administrator."
      )

  def handle_error(conn, :x509_user_not_authorized),
    do:
      ProblemDetails.send_with_code(
        conn,
        403,
        :x509_user_not_authorized,
        "This device's certificate does not identify an active user authorized to access " <>
          "this Firezone account. Please contact your administrator."
      )

  def handle_error(conn, reason) when is_map_key(@x509_rejection_details, reason) do
    ProblemDetails.send_with_code(conn, 403, reason, Map.fetch!(@x509_rejection_details, reason))
  end

  def handle_error(conn, :device_identity_conflict),
    do:
      ProblemDetails.send_with_code(
        conn,
        409,
        :device_identity_conflict,
        "This device's certificate reports different hardware than the device already " <>
          "registered under the same MDM device ID. Please contact your administrator."
      )

  def handle_error(conn, :device_certificate_invalid),
    do:
      ProblemDetails.send_with_code(
        conn,
        403,
        :device_certificate_invalid,
        "The device certificate is not from the current device CA of this account, or it " <>
          "expired. Get a new certificate and connect again."
      )

  def handle_error(conn, :device_certificate_required),
    do:
      ProblemDetails.send_with_code(
        conn,
        403,
        :device_certificate_required,
        "This device has a device key. Connect with its certificate."
      )

  def handle_error(conn, :device_key_conflict),
    do:
      ProblemDetails.send_with_code(
        conn,
        409,
        :device_key_conflict,
        "This device key or token belongs to a different device. Please contact your " <>
          "administrator to reset the identity of the device."
      )

  def handle_error(conn, :device_key_in_use),
    do:
      ProblemDetails.send_with_code(
        conn,
        409,
        :device_key_in_use,
        "Another connection uses this device key. If this machine is a copy of another " <>
          "machine, clear its state directory."
      )

  def handle_error(conn, :invalid_proto_range),
    do:
      ProblemDetails.send_with_code(
        conn,
        400,
        :invalid_proto_range,
        "proto_min and proto_max must be whole numbers with proto_min no larger than proto_max"
      )

  def handle_error(conn, :conflict),
    do:
      ProblemDetails.send_with_code(
        conn,
        409,
        :gateway_already_connected,
        "A gateway with this ID is already connected"
      )

  def handle_error(conn, %Ecto.Changeset{} = changeset) do
    Logger.error("Invalid connection request", changeset: inspect(changeset))

    ProblemDetails.send_with_code(
      conn,
      400,
      :invalid_connect_params,
      changeset_error_detail(changeset)
    )
  end

  def handle_error(conn, :rate_limit) do
    handle_error(conn, {:rate_limit, PortalAPI.Sockets.RateLimit.retry_after_seconds() * 1000})
  end

  def handle_error(conn, {:rate_limit, retry_after_ms}) do
    {status, title} = rate_limit_status(conn)

    conn
    |> Plug.Conn.put_resp_header(
      "retry-after",
      Integer.to_string(max(ceil(retry_after_ms / 1000), 1))
    )
    |> ProblemDetails.send_with_code(status, :rate_limit, title)
  end

  # Must stay last so it cannot shadow the clauses above.
  def handle_error(conn, reason) do
    Logger.error("Unhandled socket connect error", reason: inspect(reason))

    ProblemDetails.send_with_code(
      conn,
      500,
      :unhandled_connect_error,
      "An unexpected error occurred."
    )
  end

  def auth_context(%{user_agent: user_agent, x_headers: x_headers} = connect_info, type) do
    remote_ip = Portal.Sockets.remote_ip(connect_info)
    Portal.Authentication.Context.build(remote_ip, user_agent, x_headers, type)
  end

  @session_field_limits %{
    user_agent: 255,
    remote_ip_location_region: 255,
    remote_ip_location_city: 255
  }

  def truncate_session_fields(context, version) do
    context =
      Enum.reduce(@session_field_limits, context, fn {field, max}, ctx ->
        value = Map.get(ctx, field)

        if is_binary(value) and String.length(value) > max do
          Logger.warning("Truncated session field",
            field: field,
            original_length: String.length(value),
            max_length: max
          )

          Map.put(ctx, field, String.slice(value, 0, max))
        else
          ctx
        end
      end)

    version =
      if is_binary(version) and String.length(version) > 255 do
        Logger.warning("Truncated session field",
          field: :version,
          original_length: String.length(version),
          max_length: 255
        )

        String.slice(version, 0, 255)
      else
        version
      end

    {context, version}
  end

  @max_ice_candidates 64
  @max_ice_candidate_bytes 512

  @doc """
  Keeps at most #{@max_ice_candidates} ICE candidates that are strings of at most
  #{@max_ice_candidate_bytes} bytes. Returns an empty list for any other input.

  Records the number of candidates and the dropped candidates as telemetry for the
  `:client` or `:gateway` `device` that sent them.
  """
  def limit_ice_candidates(candidates, %Portal.Device{type: sender})
      when is_list(candidates) do
    Portal.Telemetry.ice_candidates_received(sender, length(candidates))

    {strings, invalid} = Enum.split_with(candidates, &is_binary/1)
    {valid, oversized} = Enum.split_with(strings, &(byte_size(&1) <= @max_ice_candidate_bytes))
    {kept, over_limit} = Enum.split(valid, @max_ice_candidates)

    Portal.Telemetry.ice_candidates_dropped(sender, :invalid, length(invalid))
    Portal.Telemetry.ice_candidates_dropped(sender, :oversized, length(oversized))
    Portal.Telemetry.ice_candidates_dropped(sender, :over_limit, length(over_limit))

    kept
  end

  def limit_ice_candidates(_candidates, %Portal.Device{}), do: []

  @doc """
  Tells every device holding an active policy authorization with `device` that it
  reconnected with a public key other than `previous_public_key`, so they drop a
  connection that still uses the old one.
  """
  def notify_public_key_changed(%Portal.Device{public_key: public_key}, public_key), do: :ok
  def notify_public_key_changed(%Portal.Device{}, nil), do: :ok

  def notify_public_key_changed(%Portal.Device{} = device, _previous_public_key) do
    message = {:public_key_changed, device.type, device.id, device.public_key}

    for peer_id <- Database.authorized_peer_ids(device) do
      Portal.PG.deliver(peer_id, message)
    end

    :ok
  end

  defp changeset_error_detail(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  defp rate_limit_status(conn) do
    retries_on_429? =
      conn
      |> Plug.Conn.get_req_header("user-agent")
      |> Enum.flat_map(&String.split(&1, " "))
      |> Enum.any?(&retries_on_429?/1)

    if retries_on_429? do
      {429, "Too Many Requests"}
    else
      {503, "Service Unavailable"}
    end
  end

  defp retries_on_429?(product) do
    with [component, version] <- String.split(product, "/", parts: 2),
         {:ok, min_version} <- Map.fetch(@retries_on_429_since, component),
         {:ok, version} <- Version.parse(version) do
      Version.compare(version, min_version) != :lt
    else
      _ -> false
    end
  end

  defp extract_token_from_header(%{x_headers: x_headers}) when is_list(x_headers) do
    case List.keyfind(x_headers, "x-authorization", 0) do
      {"x-authorization", "Bearer " <> token} -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp extract_token_from_header(_connect_info), do: {:error, :missing_token}

  defp extract_token_from_params(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp extract_token_from_params(_params), do: {:error, :missing_token}

  defmodule Database do
    import Ecto.Query

    def authorized_peer_ids(%Portal.Device{account_id: account_id, id: device_id}) do
      now = DateTime.utc_now()

      active =
        from(pa in Portal.PolicyAuthorization,
          where: pa.account_id == ^account_id,
          where: pa.expires_at > ^now
        )

      from(pa in active, where: pa.initiating_device_id == ^device_id, select: pa.receiving_device_id)
      |> union(
        ^from(pa in active, where: pa.receiving_device_id == ^device_id, select: pa.initiating_device_id)
      )
      |> Portal.Safe.unscoped()
      |> Portal.Safe.all()
    end
  end
end
