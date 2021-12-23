defmodule FzHttpWeb.SettingLive.Security do
  @moduledoc """
  Manages security LiveView
  """
  use FzHttpWeb, :live_view

  import FzCommon.FzInteger, only: [max_pg_integer: 0]

  alias FzHttp.Settings

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
  def handle_event("save", %{"setting" => %{"value" => value}}, socket) do
    key = socket.assigns.changeset.data.key

    case Settings.update_setting(key, value) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:form_changed, false)
         |> assign(:changeset, Settings.change_setting(setting, %{}))}

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
        Once: max_pg_integer(),
        "Every Hour": @hour,
        "Every Day": @day,
        "Every Week": 7 * @day,
        "Every 30 Days": 30 * @day,
        "Every 90 Days": 90 * @day
      ]

      setting = Settings.get_setting!(key: "security.require_auth_for_vpn_frequency")
      changeset = Settings.change_setting(setting)

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
