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
      for reason <- [:econnaborted, :econnreset] do
        event = thousand_island_termination_event(reason)

        assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
      end
    end

    test "relevels a client-canceled TLS connection to info" do
      event =
        thousand_island_termination_event(
          {:tls_alert, {:user_canceled, ~c"TLS server: client canceled"}}
        )

      assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
    end

    test "relevels Bandit HTTP 4xx errors to info" do
      for status <- [:bad_request, :request_timeout, 431] do
        event = bandit_event(%Bandit.HTTPError{message: "client error", plug_status: status})

        assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
      end
    end

    test "relevels Bandit client closures to info" do
      event = bandit_event(%Bandit.TransportError{message: "closed", error: :closed})

      assert %{level: :info} = LoggerFilters.relevel_expected_client_errors(event, nil)
    end

    test "leaves server-side Bandit errors at error" do
      http_error = bandit_event(%Bandit.HTTPError{message: "server error", plug_status: 500})
      transport_error = bandit_event(%Bandit.TransportError{message: "socket error", error: :eio})

      assert LoggerFilters.relevel_expected_client_errors(http_error, nil) == :ignore
      assert LoggerFilters.relevel_expected_client_errors(transport_error, nil) == :ignore
    end

    test "leaves other TLS alerts at error" do
      event =
        thousand_island_termination_event(
          {:tls_alert, {:handshake_failure, ~c"TLS server: handshake failure"}}
        )

      assert LoggerFilters.relevel_expected_client_errors(event, nil) == :ignore
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
    %{
      level: :error,
      msg:
        {:report,
         %{
           label: {:gen_server, :terminate},
           process_label:
             {:thousand_island, :connection, {Bandit.DelegatingHandler, {{127, 0, 0, 1}, 443}}},
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
