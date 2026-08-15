defmodule Portal.LoggerFilters do
  @moduledoc false

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
              process_label: {:thousand_island, :connection, _connection},
              reason: reason
            }}
       }) do
    expected_thousand_island_error?(reason)
  end

  defp expected_client_error?(%{
         meta: %{domain: domain, crash_reason: {reason, _stacktrace}}
       })
       when is_list(domain) do
    :bandit in domain and expected_bandit_error?(reason)
  end

  defp expected_client_error?(_event), do: false

  defp expected_thousand_island_error?(
         {%Bandit.TransportError{
            message: "Unable to obtain conn_data",
            error: :einval
          }, _stacktrace}
       ),
       do: true

  defp expected_thousand_island_error?(reason) when reason in [:econnaborted, :econnreset],
    do: true

  defp expected_thousand_island_error?({:tls_alert, {:user_canceled, _description}}),
    do: true

  defp expected_thousand_island_error?(_reason), do: false

  defp expected_bandit_error?(%Bandit.HTTPError{plug_status: status}),
    do: client_error_status?(status)

  defp expected_bandit_error?(%Bandit.TransportError{error: reason})
       when reason in [:closed, :econnaborted, :econnreset],
       do: true

  defp expected_bandit_error?(_reason), do: false

  defp client_error_status?(status) do
    Plug.Conn.Status.code(status) in 400..499
  rescue
    FunctionClauseError -> false
  end
end
