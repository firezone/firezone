defmodule FzHttpWeb.LiveAuth do
  @moduledoc """
  Handles loading default assigns and authorizing.
  """

  use Phoenix.Component
  alias FzHttpWeb.Auth.HTML.Authentication
  import FzHttpWeb.AuthorizationHelpers

  require Logger

  def on_mount(role, _params, session, socket) do
    do_on_mount(role, Authentication.get_current_user(session), socket)
  end

  defp do_on_mount(_role, nil, socket) do
    Logger.warn("Could not get_current_user from session in LiveAuth.on_mount/4.")
    {:halt, not_authorized(socket)}
  end

  # XXX: A hack for now, will be going away with client apps
  defp do_on_mount(
         :unprivileged,
         %{role: :unprivileged} = user,
         %{assigns: %{live_action: :new}, view: FzHttpWeb.DeviceLive.Unprivileged.Index} = socket
       ) do
    if FzHttp.Config.fetch_config!(:allow_unprivileged_device_management) do
      {:cont, assign_new(socket, :current_user, fn -> user end)}
    else
      {:halt, not_authorized(socket)}
    end
  end

  defp do_on_mount(role, user, socket) do
    socket
    |> assign_new(:current_user, fn -> user end)
    |> authorize_role(role)
  end
end
