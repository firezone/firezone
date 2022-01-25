defmodule FzCommon.MockTelemetry do
  @moduledoc """
  Mock Posthog wrapper.
  """

  @response {:ok,
             %{
               body: %{"status" => 1},
               headers: [
                 {"Date", "Tue, 25 Jan 2022 06:14:47 GMT"},
                 {"Content-Type", "application/json"},
                 {"Content-Length", "13"},
                 {"Connection", "keep-alive"},
                 {"X-Frame-Options", "DENY"},
                 {"Vary", "Cookie"},
                 {"X-Content-Type-Options", "nosniff"},
                 {"Referrer-Policy", "same-origin"},
                 {"Strict-Transport-Security", "max-age=15724800; includeSubDomains"}
               ],
               status: 200
             }}

  def capture(_event, _metadata) do
    @response
  end

  def batch(events) when is_list(events) do
    @response
  end
end
