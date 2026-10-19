defmodule PortalWeb.Analytics do
  @moduledoc """
  Sends portal page views and actions to PostHog from LiveView telemetry, so no
  LiveView needs instrumenting and no analytics code runs in the browser.

  Only the LiveView or LiveComponent module, the event name and the route pattern
  (e.g. `/:account_id_or_slug/resources/:id`) are sent. Params, form input and raw
  URLs are never sent: they hold account slugs, resource addresses and other
  customer-entered data.

  Events are only sent for signed-in actors. Their account and actor are recorded
  when the page is viewed, because LiveComponent sockets don't carry the subject.
  """

  require Logger

  alias Portal.Analytics.PostHog
  alias Portal.Authentication.Subject

  @handler_id "portal-web-analytics"

  @events [
    [:phoenix, :live_view, :handle_params, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_component, :handle_event, :stop]
  ]

  # Per-keystroke events that would drown out deliberate actions.
  @noisy_events ~w[handle_keydown]

  @context_key {__MODULE__, :context}

  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  # Telemetry detaches a handler that raises, which would silently stop all
  # analytics, so failures are logged and swallowed.
  def handle_event(event, _measurements, metadata, _config) do
    if PostHog.enabled?(), do: track(event, metadata)
    :ok
  rescue
    exception ->
      Logger.warning("Portal analytics event failed", reason: Exception.message(exception))
      :ok
  end

  defp track([:phoenix, :live_view, :handle_params, :stop], %{socket: socket, uri: uri}) do
    with true <- Phoenix.LiveView.connected?(socket),
         %Subject{} = subject <- socket.assigns[:subject],
         {:ok, route} <- route_pattern(socket.router, uri) do
      previous = Process.get(@context_key)

      context = %{
        distinct_id: subject.actor.id,
        account_id: subject.account.id,
        view: inspect(socket.view),
        route: route
      }

      Process.put(@context_key, context)

      # A LiveView process is one page, and patches within it only change query
      # params (filters, sorting, pagination), so a page view is sent once per
      # route rather than on every patch.
      if is_nil(previous) or previous.route != route do
        PostHog.capture_async(
          "$pageview",
          context.distinct_id,
          base_properties(context)
          |> Map.put("$current_url", PortalWeb.Endpoint.url() <> route)
          |> Map.put("live_action", live_action(socket))
        )
      end
    end

    :ok
  end

  defp track([:phoenix, kind, :handle_event, :stop], %{event: event, params: params} = metadata)
       when kind in [:live_view, :live_component] do
    with %{} = context <- Process.get(@context_key),
         true <- trackable_event?(event, params) do
      properties =
        context
        |> base_properties()
        |> Map.put("action", event)
        |> maybe_put_component(metadata)

      PostHog.capture_async("Portal Action", context.distinct_id, properties)
    end

    :ok
  end

  defp base_properties(context) do
    %{
      "$process_person_profile" => false,
      "$groups" => %{"account" => context.account_id},
      "$pathname" => context.route,
      "view" => context.view
    }
  end

  defp maybe_put_component(properties, %{component: component}),
    do: Map.put(properties, "component", inspect(component))

  defp maybe_put_component(properties, _metadata), do: properties

  defp live_action(%{assigns: %{live_action: action}}) when is_atom(action) and not is_nil(action),
    do: Atom.to_string(action)

  defp live_action(_socket), do: nil

  # phx-change events carry `_target` and fire on every keystroke. Event names
  # come from templates, but are checked anyway so nothing unexpected is sent.
  defp trackable_event?(event, params) do
    event not in @noisy_events and not (is_map(params) and Map.has_key?(params, "_target")) and
      Regex.match?(~r/\A[a-z0-9_]{1,64}\z/, event)
  end

  defp route_pattern(router, uri) do
    %URI{host: host, path: path} = URI.parse(uri)

    case Phoenix.Router.route_info(router, "GET", path || "/", host) do
      %{route: route} -> {:ok, route}
      :error -> :error
    end
  end
end
