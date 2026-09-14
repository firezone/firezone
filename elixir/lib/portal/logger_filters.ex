defmodule Portal.LoggerFilters do
  @moduledoc false

  # :einval means Bandit asked a socket for peer data after the client already hung up.
  @client_socket_errors [
    :closed,
    :econnaborted,
    :econnreset,
    :einval,
    :enotconn,
    :epipe,
    :etimedout
  ]

  # Only post-handshake alerts land here, Thousand Island exits with :shutdown during a handshake.
  @client_tls_alerts [
    :bad_record_mac,
    :close_notify,
    :decode_error,
    :decrypt_error,
    :illegal_parameter,
    :record_overflow,
    :unexpected_message,
    :user_canceled
  ]

  def relevel_expected_client_errors(%{level: :error} = event, _extra) do
    if expected_client_error?(event) do
      %{event | level: :info}
    else
      :ignore
    end
  end

  def relevel_expected_client_errors(_event, _extra), do: :ignore

  defp expected_client_error?(%{
         msg:
           {:report,
            %{
              label: {:gen_server, :terminate},
              process_label: process_label,
              reason: reason
            }}
       }) do
    client_connection_process?(process_label) and expected_reason?(reason)
  end

  defp expected_client_error?(%{meta: %{domain: domain, crash_reason: crash_reason}})
       when is_list(domain) do
    :bandit in domain and expected_reason?(crash_reason)
  end

  defp expected_client_error?(_event), do: false

  # Phoenix relabels the transport process, so a WebSocket connection terminates as
  # {Phoenix.Socket, _, _} instead of {:thousand_island, :connection, _}, and its
  # channels exit with the same reason.
  defp client_connection_process?({:thousand_island, :connection, _connection}), do: true
  defp client_connection_process?({Phoenix.Socket, _handler, _id}), do: true
  defp client_connection_process?({Phoenix.Channel, _channel, _topic}), do: true
  defp client_connection_process?(_process_label), do: false

  defp expected_reason?({:tls_alert, {alert, _description}}), do: alert in @client_tls_alerts

  defp expected_reason?({reason, stacktrace}) when is_list(stacktrace),
    do: expected_reason?(reason)

  defp expected_reason?(%Bandit.HTTPError{plug_status: status}), do: client_error_status?(status)

  defp expected_reason?(%Bandit.TransportError{error: error}), do: error in @client_socket_errors

  defp expected_reason?(reason), do: reason in @client_socket_errors

  defp client_error_status?(status) do
    Plug.Conn.Status.code(status) in 400..499
  rescue
    FunctionClauseError -> false
  end
end
