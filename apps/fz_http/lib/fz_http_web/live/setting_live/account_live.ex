defmodule FzHttpWeb.SettingLive.Account do
  @moduledoc """
  Handles Account-related things for admins.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{MFA, Users}
  alias FzHttpWeb.{Endpoint, Presence}

  @live_sessions_topic "notification:session"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    Endpoint.subscribe(@live_sessions_topic)

    {:ok,
     socket
     |> assign(:changeset, Users.change_user(socket.assigns.current_user))
     |> assign(:methods, MFA.list_methods(socket.assigns.current_user))
     |> assign(:page_title, "Account Settings")
     |> assign(:rules_path, Routes.rule_index_path(socket, :index))
     |> assign(
       :metas,
       get_metas(Presence.list(@live_sessions_topic), socket.assigns.current_user.id)
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    admins = Users.list_admins()
    {:noreply, assign(socket, :allow_delete, length(admins) > 1)}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_authenticator", %{"id" => id}, socket) do
    {:ok, _deleted} = id |> MFA.get_method!() |> MFA.delete_method()

    {:noreply,
     socket
     |> assign(:methods, MFA.list_methods(socket.assigns.current_user))}
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
    get_in(presences, [to_string(user_id), :metas]) || []
  end
end
