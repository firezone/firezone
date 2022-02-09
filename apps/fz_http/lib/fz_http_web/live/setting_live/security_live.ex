defmodule FzHttpWeb.SettingLive.Security do
  @moduledoc """
  Manages security LiveView
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Sites, Sites.Site}

  @hour 3_600
  @day 24 * @hour

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)}
  end

  @impl Phoenix.LiveView
  def handle_event("change", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_changed, true)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"site" => %{"key_ttl" => key_ttl}}, socket) do
    site = Sites.get_site!()

    case Sites.update_site(site, %{key_ttl: key_ttl}) do
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

  defp load_data(_params, socket) do
    user = socket.assigns.current_user

    if user.role == :admin do
      options = [
        Never: 0,
        Once: Site.max_key_ttl(),
        "Every Hour": @hour,
        "Every Day": @day,
        "Every Week": 7 * @day,
        "Every 30 Days": 30 * @day,
        "Every 90 Days": 90 * @day
      ]

      site = Sites.get_site!()
      changeset = Sites.change_site(site)

      socket
      |> assign(:form_changed, false)
      |> assign(:options, options)
      |> assign(:changeset, changeset)
      |> assign(:page_title, "Security Settings")
    else
      not_authorized(socket)
    end
  end
end
