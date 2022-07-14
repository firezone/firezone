defmodule FzHttpWeb.SettingLive.Customization do
  @moduledoc """
  Manages the app customizations.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Conf

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Customization")
     |> assign(:config, Conf.get_configuration!())
     |> assign(:uploaded_files, [])
     |> allow_upload(:logo,
       accept: ~w(.jpg .jpeg .png .gif .webp .avif .svg .tiff),
       max_entries: 1,
       max_file_size: 256 * 1024
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"url" => url}, socket) do
    {:ok, config} =
      Conf.update_configuration(socket.assigns.config, %{
        logo: %{"url" => url}
      })

    {:noreply, assign(socket, :config, config)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", _params, socket) do
    {[entry], []} = uploaded_entries(socket, :logo)

    config =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        data = path |> File.read!() |> Base.encode64()

        # enforce OK, error from update_configuration instead of consume_uploaded_entry
        {:ok, config} =
          Conf.update_configuration(socket.assigns.config, %{
            logo: %{"data" => data, "type" => entry.client_type}
          })

        {:ok, config}
      end)

    {:noreply, assign(socket, :config, config)}
  end

  defp error_to_string(:too_large), do: "The file is too large"
  defp error_to_string(:too_many_files), do: "You have selected too many files"
  defp error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

  defp preview_logo(nil), do: nil

  defp preview_logo(%{"url" => url} = assigns) do
    ~H"""
    <img src={url} alt="Firezone App Logo" />
    """
  end

  defp preview_logo(%{"data" => data, "type" => type} = assigns) do
    ~H"""
    <img src={"data:#{type};base64," <> data} alt="Firezone App Logo" />
    """
  end
end
