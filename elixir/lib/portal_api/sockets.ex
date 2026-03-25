defmodule PortalAPI.Sockets do
  @moduledoc """
  This module provides a set of helper function for Phoenix sockets and
  error handling around them.
  """
  require Logger

  alias PortalAPI.ProblemDetails

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
    do: ProblemDetails.send(conn, 401, "Invalid token")

  def handle_error(conn, :missing_token),
    do: ProblemDetails.send(conn, 401, "Missing token")

  def handle_error(conn, :limits_exceeded),
    do:
      ProblemDetails.send(
        conn,
        402,
        "This account is temporarily suspended from client authentication " <>
          "due to exceeding billing limits. Please contact your administrator to add more seats."
      )

  def handle_error(conn, :account_disabled),
    do: ProblemDetails.send(conn, 403, "The account is disabled")

  def handle_error(conn, :unauthenticated),
    do: ProblemDetails.send(conn, 403, "Forbidden")

  def handle_error(conn, %Ecto.Changeset{} = changeset) do
    Logger.error("Invalid connection request", changeset: inspect(changeset))
    ProblemDetails.send(conn, 400, changeset_error_detail(changeset))
  end

  # We use 503 instead of 429 because connlib treats 429 as fatal until
  # https://github.com/firezone/firezone/pull/11594 is widely distributed.
  def handle_error(conn, :rate_limit) do
    conn
    |> Plug.Conn.put_resp_header(
      "retry-after",
      Integer.to_string(PortalAPI.Sockets.RateLimit.retry_after_seconds())
    )
    |> ProblemDetails.send(503, "Service Unavailable")
  end

  def auth_context(%{user_agent: user_agent, x_headers: x_headers, peer_data: peer_data}, type) do
    remote_ip = real_ip(x_headers, peer_data)
    Portal.Authentication.Context.build(remote_ip, user_agent, x_headers, type)
  end

  defp real_ip(x_headers, peer_data) do
    real_ip =
      if is_list(x_headers) and x_headers != [] do
        RemoteIp.from(x_headers, PortalAPI.Endpoint.real_ip_opts())
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
