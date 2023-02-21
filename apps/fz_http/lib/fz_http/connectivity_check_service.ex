defmodule FzHttp.ConnectivityCheckService do
  @moduledoc """
  A simple GenServer to periodically check for WAN connectivity by issuing
  POSTs to https://ping[-dev].firez.one/{version}.
  """
  use GenServer

  require Logger

  alias FzHttp.ConnectivityChecks

  # Wait a minute before sending the first ping to avoid event spamming when
  # a container is stuck in a reboot loop.
  @initial_delay 60 * 1_000

  def start_link(_) do
    http_client().start()
    GenServer.start_link(__MODULE__, %{})
  end

  @impl GenServer
  def init(state) do
    if enabled?() do
      :timer.send_after(@initial_delay, :init_timer)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:init_timer, _state) do
    :timer.send_interval(interval(), :perform)
    {:noreply, post_request()}
  end

  # XXX: Consider passing state here to implement exponential backoff in case of errors.
  @impl GenServer
  def handle_info(:perform, _state) do
    {:noreply, post_request()}
  end

  def post_request, do: post_request(url())

  def post_request(request_url) do
    body = ""

    case http_client().post(request_url, body, [], http_client_options()) do
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

  def initialize do
    if !ConnectivityChecks.exists?() && enabled?() do
      post_request()
    end
  end

  defp url do
    FzHttp.Config.fetch_env!(:fz_http, :connectivity_checks_url) <> version()
  end

  defp http_client do
    FzHttp.Config.fetch_env!(:fz_http, :http_client)
  end

  defp version do
    Application.spec(:fz_http, :vsn) |> to_string()
  end

  defp interval do
    FzHttp.Config.fetch_env!(:fz_http, :connectivity_checks_interval) * 1_000
  end

  defp enabled? do
    FzHttp.Config.fetch_env!(:fz_http, :connectivity_checks_enabled)
  end

  defp http_client_options do
    FzHttp.Config.fetch_env!(:fz_http, :http_client_options)
  end
end
