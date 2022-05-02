defmodule FzHttpWeb.SettingLive.Security do
  @moduledoc """
  Manages security LiveView
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Sites, Sites.Site}

  @hour 3_600
  @day 24 * @hour

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form_changed, false)
     |> assign(:session_duration_options, session_duration_options())
     |> assign(:changeset, changeset())
     |> assign(:page_title, "Security Settings")}
  end

  @impl Phoenix.LiveView
  def handle_event("change", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_changed, true)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"site" => %{"vpn_session_duration" => vpn_session_duration}}, socket) do
    site = Sites.get_site!()

    case Sites.update_site(site, %{vpn_session_duration: vpn_session_duration}) do
      {:ok, site} ->
        {:noreply,
         socket
         |> assign(:form_changed, false)
         |> assign(:changeset, Sites.change_site(site))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)}
    end
  end

  def session_duration_options do
    [
      Never: 0,
      Once: Site.max_vpn_session_duration(),
      "Every Hour": @hour,
      "Every Day": @day,
      "Every Week": 7 * @day,
      "Every 30 Days": 30 * @day,
      "Every 90 Days": 90 * @day
    ]
  end

  defp changeset do
    Sites.get_site!()
    |> Sites.change_site()
  end
end
