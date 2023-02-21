defmodule FzHttpWeb.SettingLive.Unprivileged.Account do
  @moduledoc """
  Handles Account-related things for unprivileged users.

  XXX: At this moment, this is a carbon copy of the admin account live view.
  Only the html is going to be different. This serves its purpose until a
  redesign happens.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{MFA, Users}
  alias FzHttpWeb.{Endpoint, Presence}

  @live_sessions_topic "notification:session"
  @page_title "Account Settings"
  @page_subtitle "Configure account settings."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    Endpoint.subscribe(@live_sessions_topic)

    {:ok, methods} = MFA.list_methods_for_user(socket.assigns.current_user)

    socket =
      socket
      |> assign(:local_auth_enabled, FzHttp.Config.fetch_config!(:local_auth_enabled))
      |> assign(:changeset, Users.change_user(socket.assigns.current_user))
      |> assign(:methods, methods)
      |> assign(:page_title, @page_title)
      |> assign(:page_subtitle, @page_subtitle)
      |> assign(
        :metas,
        get_metas(Presence.list(@live_sessions_topic), socket.assigns.current_user.id)
      )

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_authenticator", %{"id" => id}, socket) do
    with {:ok, _method} <- MFA.delete_method_by_id(id, socket.assigns.current_user) do
      {:ok, methods} = MFA.list_methods_for_user(socket.assigns.current_user)
      {:noreply, assign(socket, :methods, methods)}
    else
      {:error, :not_found} ->
        {:ok, methods} = MFA.list_methods_for_user(socket.assigns.current_user)
        {:noreply, assign(socket, :methods, methods)}

      false ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(
        %{event: "presence_diff", payload: %{joins: joins, leaves: leaves}},
        %{assigns: %{metas: metas}} = socket
      ) do
    metas =
      (metas ++
         get_metas(joins, socket.assigns.current_user.id)) --
        get_metas(leaves, socket.assigns.current_user.id)

    {:noreply, assign(socket, :metas, metas)}
  end

  defp get_metas(presences, user_id) do
    get_in(presences, [user_id, :metas]) || []
  end
end
