defmodule FzHttpWeb.SettingLive.ClientDefaultsFormComponent do
  @moduledoc """
  Handles updating client defaults form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Configurations

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"configuration" => configuration_params}, socket) do
    configuration = Configurations.get_configuration!()

    case Configurations.update_configuration(configuration, configuration_params) do
      {:ok, configuration} ->
        {:noreply,
         socket
         |> assign(:changeset, Configurations.change_configuration(configuration))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)}
    end
  end
end
