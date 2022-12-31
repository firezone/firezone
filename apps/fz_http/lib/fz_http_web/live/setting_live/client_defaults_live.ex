defmodule FzHttpWeb.SettingLive.ClientDefaults do
  @moduledoc """
  Manages the defaults view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Configurations

  @page_title "Client Defaults"
  @page_subtitle "Configure default values for generating WireGuard client configurations."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:changeset, changeset())
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
  end

  defp changeset do
    Configurations.get_configuration!() |> Configurations.change_configuration()
  end
end
