defmodule FzHttpWeb.SettingLive.FormComponent do
  @moduledoc """
  Handles updating setting values, one at a time
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Settings

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:input_class, "input")
     |> assign(:form_changed, false)
     |> assign(:input_icon, "")
     |> assign(assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"setting" => %{"value" => value}}, socket) do
    key = socket.assigns.changeset.data.key

    case Settings.update_setting(key, value) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:input_class, input_class(false))
         |> assign(:input_icon, input_icon(false))
         |> assign(:changeset, Settings.change_setting(setting, %{}))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:input_class, input_class(true))
         |> assign(:input_icon, input_icon(true))
         |> assign(:changeset, changeset)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_changed, true)}
  end

  defp input_icon(false) do
    "mdi mdi-check-circle"
  end

  defp input_icon(true) do
    "mdi mdi-alert-circle"
  end

  defp input_class(false) do
    "input is-success"
  end

  defp input_class(true) do
    "input is-danger"
  end
end
