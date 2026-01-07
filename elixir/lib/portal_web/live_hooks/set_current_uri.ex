defmodule PortalWeb.LiveHooks.SetCurrentUri do
  @moduledoc """
  A unified live hook that parses the current URI and sets:

    - `@current_path` - the path portion of the URI (used by sidebar for active state)
    - `@query_params` - decoded query parameters as a map (used by live_table, navigation, modals)
    - `@return_to` - the full URI with path and encoded query params (used for return_to links)

  This consolidates the functionality previously split across SetActiveSidebarItem
  and HandleModalReturn hooks.
  """

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :set_current_uri, :handle_params, &set_current_uri/3)}
  end

  defp set_current_uri(_params, uri, socket) do
    parsed = URI.parse(uri)

    query_params =
      if parsed.query do
        URI.decode_query(parsed.query)
      else
        %{}
      end

    return_to =
      if query_params == %{} do
        parsed.path
      else
        "#{parsed.path}?#{URI.encode_query(query_params)}"
      end

    socket =
      Phoenix.Component.assign(socket,
        current_path: parsed.path,
        query_params: query_params,
        return_to: return_to
      )

    {:cont, socket}
  end
end
