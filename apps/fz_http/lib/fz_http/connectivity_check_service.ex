defmodule FzHttp.ConnectivityCheckService do
  @moduledoc """
  A simple GenServer to periodically check for WAN connectivity by issuing
  POSTs to https://ping[-dev].firez.one/{version}.
  """
  use GenServer

  require Logger

  alias FzHttp.{ConnectivityChecks, Telemetry}

  def start_link(_) do
    http_client().start()
    GenServer.start_link(__MODULE__, %{})
  end

  @impl GenServer
  def init(state) do
    if enabled?() do
      :timer.send_interval(interval(), :perform)
    end

    {:ok, state}
  end

  # XXX: Consider passing state here to implement exponential backoff in case of errors.
  @impl GenServer
  def handle_info(:perform, _state) do
    Telemetry.ping()
    {:noreply, post_request()}
  end

  def post_request, do: post_request(url())

  def post_request(request_url) do
    body = ""

    case http_client().post(request_url, body) do
      {:ok, response} ->
        ConnectivityChecks.create_connectivity_check(%{
          response_body: response.body,
          response_code: response.status_code,
          response_headers: Map.new(response.headers),
          url: request_url
        })

        response

      {:error, error} ->
        Logger.error("""
        An unexpected error occurred while performing a Firezone connectivity check to #{request_url}. Reason: #{error.reason}
        """)

        error
    end
  end

  defp url do
    Application.fetch_env!(:fz_http, :connectivity_checks_url) <> version()
  end

  defp http_client do
    Application.fetch_env!(:fz_http, :http_client)
  end

  defp version do
    Application.spec(:fz_http, :vsn) |> to_string()
  end

  defp interval do
    Application.fetch_env!(:fz_http, :connectivity_checks_interval) * 1_000
  end

  defp enabled? do
    Application.fetch_env!(:fz_http, :connectivity_checks_enabled)
  end
end
