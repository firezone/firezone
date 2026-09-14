defmodule Portal.LoggerFiltersTest do
  use ExUnit.Case, async: true

  alias Portal.LoggerFilters

  describe "relevel_expected_client_errors/2" do
    test "relevels a closed conn_data lookup to info" do
      event =
        thousand_island_termination_event(
          {%Bandit.TransportError{
             message: "Unable to obtain conn_data",
             error: :einval
           }, []}
        )

      assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
    end

    test "relevels peer-aborted Thousand Island connections to info" do
      for reason <- [:closed, :econnaborted, :econnreset, :einval, :enotconn, :epipe, :etimedout] do
        event = thousand_island_termination_event(reason)

        assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
      end
    end

    test "relevels client TLS alerts to info" do
      for alert <- [
            :bad_record_mac,
            :close_notify,
            :decode_error,
            :decrypt_error,
            :illegal_parameter,
            :record_overflow,
            :unexpected_message,
            :user_canceled
          ] do
        event =
          thousand_island_termination_event({:tls_alert, {alert, ~c"TLS server: #{alert}"}})

        assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
      end
    end

    test "relevels Bandit HTTP 4xx errors to info" do
      for status <- [:bad_request, :request_timeout, 431] do
        event = bandit_event(%Bandit.HTTPError{message: "client error", plug_status: status})

        assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
      end
    end

    test "relevels Bandit client closures to info" do
      for error <- [:closed, :econnaborted, :econnreset, :einval, :enotconn, :epipe, :etimedout] do
        event = bandit_event(%Bandit.TransportError{message: "socket gone", error: error})

        assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
      end
    end

    test "relevels a closed socket lookup reported by Bandit to info" do
      event =
        bandit_event(%Bandit.TransportError{message: "Unable to obtain conn_data", error: :einval})

      assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
    end

    test "leaves server-side Bandit errors at error" do
      http_error = bandit_event(%Bandit.HTTPError{message: "server error", plug_status: 500})
      transport_error = bandit_event(%Bandit.TransportError{message: "socket error", error: :eio})

      assert LoggerFilters.relevel_expected_client_errors(http_error, nil) == :ignore
      assert LoggerFilters.relevel_expected_client_errors(transport_error, nil) == :ignore
    end

    test "relevels client TLS alerts on WebSocket sockets and channels to info" do
      for process_label <- [
            {Phoenix.Socket, PortalAPI.Client.Socket, "socket:16365c49-6446-4de9-be3b-1840db805315"},
            {Phoenix.Channel, PortalAPI.Client.Channel, "client"}
          ] do
        event =
          termination_event(
            process_label,
            {:tls_alert, {:bad_record_mac, ~c"TLS server: Bad Record MAC"}}
          )

        assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
      end
    end

    test "leaves terminations of other labeled processes at error" do
      event =
        termination_event(
          {:gen_statem, Portal.Replication.SlotPoller},
          {:tls_alert, {:bad_record_mac, ~c"TLS server: Bad Record MAC"}}
        )

      assert LoggerFilters.relevel_expected_client_errors(event, nil) == :ignore
    end

    test "leaves other TLS alerts at error" do
      for alert <- [:handshake_failure, :internal_error, :unrecognized_name] do
        event = thousand_island_termination_event({:tls_alert, {alert, ~c"TLS server: #{alert}"}})

        assert LoggerFilters.relevel_expected_client_errors(event, nil) == :ignore
      end
    end

    test "leaves application crashes inside a connection at error" do
      call_timeout =
        thousand_island_termination_event(
          {:timeout, {GenServer, :call, [Portal.Repo, :checkout, 5000]}}
        )

      badmatch = thousand_island_termination_event({{:badmatch, [:oops]}, []})

      assert LoggerFilters.relevel_expected_client_errors(call_timeout, nil) == :ignore
      assert LoggerFilters.relevel_expected_client_errors(badmatch, nil) == :ignore
    end

    test "leaves telemetry handler failures at error" do
      event = %{
        level: :error,
        msg:
          {:report,
           %{
             handler_id: {OpentelemetryBandit, :otel_bandit},
             reason: %Bandit.TransportError{
               message: "Unable to obtain peer_data",
               error: :einval
             }
           }},
        meta: %{domain: [:telemetry]}
      }

      assert LoggerFilters.relevel_expected_client_errors(event, nil) == :ignore
    end

    test "leaves unrelated logger events at error" do
      event = %{level: :error, msg: {:string, "an application error"}, meta: %{}}

      assert LoggerFilters.relevel_expected_client_errors(event, nil) == :ignore
    end
  end

  defp thousand_island_termination_event(reason) do
    termination_event(
      {:thousand_island, :connection, {Bandit.DelegatingHandler, {{127, 0, 0, 1}, 443}}},
      reason
    )
  end

  defp termination_event(process_label, reason) do
    %{
      level: :error,
      msg:
        {:report,
         %{
           label: {:gen_server, :terminate},
           process_label: process_label,
           reason: reason
         }},
      meta: %{domain: [:otp]}
    }
  end

  defp bandit_event(reason) do
    %{
      level: :error,
      msg: {:string, Exception.message(reason)},
      meta: %{domain: [:elixir, :bandit], crash_reason: {reason, []}}
    }
  end
end
