defmodule Web.SettingLive.Customization do
  @moduledoc """
  Manages the app customizations.
  """
  use Web, :live_view
  alias Domain.Config

  @max_logo_size 1024 ** 2
  @page_title "Customization"
  @page_subtitle "Customize the look and feel of your Firezone web portal."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {source, logo} = Domain.Config.fetch_source_and_config!(:logo)
    logo_type = Domain.Config.Logo.type(logo)

    socket =
      socket
      |> assign(:page_title, @page_title)
      |> assign(:page_subtitle, @page_subtitle)
      |> assign(:logo, logo)
      |> assign(:logo_source, source)
      |> assign(:logo_type, logo_type)
      |> allow_upload(:logo,
        accept: ~w(.jpg .jpeg .png .gif .webp .avif .svg .tiff),
        max_file_size: @max_logo_size
      )

    {:ok, socket}
  end

  def has_override?({source, _source_key}), do: source not in [:db]
  def has_override?(_source), do: false

  @impl Phoenix.LiveView
  def handle_event("choose", %{"type" => type}, socket) do
    {:noreply, assign(socket, :logo_type, type)}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"default" => "true"}, socket) do
    {:ok, config} =
      Config.fetch_db_config!()
      |> Config.update_config(%{logo: nil}, socket.assigns.subject)

    {:noreply, assign(socket, :logo, config.logo)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"url" => url}, socket) do
    {:ok, config} =
      Config.fetch_db_config!()
      |> Config.update_config(%{logo: %{"url" => url}}, socket.assigns.subject)

    {:noreply, assign(socket, :logo, config.logo)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", _params, socket) do
    {[entry], []} = uploaded_entries(socket, :logo)

    config =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        data =
          path
          |> File.read!()
          |> Base.encode64()

        {:ok, config} =
          Config.fetch_db_config!()
          |> Config.update_config(
            %{logo: %{"data" => data, "type" => entry.client_type}},
            socket.assigns.subject
          )

        {:ok, config}
      end)

    {:noreply, assign(socket, :logo, config.logo)}
  end

  defp error_to_string(:too_large), do: "The file exceeds the maximum size of 1MB."
  defp error_to_string(:too_many_files), do: "You have selected too many files."
  defp error_to_string(:not_accepted), do: "You have selected an unacceptable file type."
end
