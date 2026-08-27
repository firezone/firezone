defmodule PortalAPI.Sockets do
  @moduledoc """
  This module provides a set of helper function for Phoenix sockets and
  error handling around them.
  """
  require Logger

  alias PortalAPI.ProblemDetails

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

  # We use 503 instead of 429 because connlib treats 429 as fatal until
  # https://github.com/firezone/firezone/pull/11594 is widely distributed.
  def handle_error(conn, :rate_limit) do
    conn
    |> Plug.Conn.put_resp_header(
      "retry-after",
      Integer.to_string(PortalAPI.Sockets.RateLimit.retry_after_seconds())
    )
    |> ProblemDetails.send_with_code(503, :rate_limit, "Service Unavailable")
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

  def auth_context(%{user_agent: user_agent, x_headers: x_headers, peer_data: peer_data}, type) do
    remote_ip = real_ip(x_headers, peer_data)
    Portal.Authentication.Context.build(remote_ip, user_agent, x_headers, type)
  end

  defp real_ip(x_headers, peer_data) do
    real_ip =
      if is_list(x_headers) and x_headers != [] do
        RemoteIp.from(x_headers, Portal.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
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

  defp extract_token_from_header(%{x_headers: x_headers}) when is_list(x_headers) do
    case List.keyfind(x_headers, "x-authorization", 0) do
      {"x-authorization", "Bearer " <> token} -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp extract_token_from_header(_connect_info), do: {:error, :missing_token}

  defp extract_token_from_params(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp extract_token_from_params(_params), do: {:error, :missing_token}
end
