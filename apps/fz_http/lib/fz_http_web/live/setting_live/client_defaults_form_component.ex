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
    configuration_params =
      configuration_params
      |> Map.update("default_client_dns", nil, &binary_to_list/1)
      |> Map.update("default_client_allowed_ips", nil, &binary_to_list/1)

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

  defp binary_to_list(binary) when is_binary(binary),
    do: binary |> String.trim() |> String.split(",")

  defp binary_to_list(list) when is_list(list),
    do: list
end
