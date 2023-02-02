defmodule FzHttpWeb.SettingLive.Security do
  @moduledoc """
  Manages security LiveView
  """
  use FzHttpWeb, :live_view

  import Ecto.Changeset
  import FzCommon.FzCrypto, only: [rand_string: 1]

  alias FzHttp.Configurations

  @page_title "Security Settings"
  @page_subtitle "Configure security-related settings."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    config_changeset = Configurations.change_configuration()

    {:ok,
     socket
     |> assign(:form_changed, false)
     |> assign(:session_duration_options, session_duration_options())
     |> assign(:configuration_changeset, configuration_changeset())
     |> assign(:config_changeset, config_changeset)
     |> assign(:oidc_configs, map_providers(config_changeset.data.openid_connect_providers))
     |> assign(:saml_configs, map_providers(config_changeset.data.saml_identity_providers))
     |> assign(:field_titles, field_titles(config_changeset))
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
  end

  defp map_providers(nil), do: %{}

  defp map_providers(providers) when is_list(providers) do
    for provider <- providers,
        into: %{},
        do: {provider.id, Map.from_struct(provider)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :id, params["id"])}
  end

  @impl Phoenix.LiveView
  def handle_event("change", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_changed, true)}
  end

  @impl Phoenix.LiveView
  def handle_event(
        "save_configuration",
        %{"configuration" => %{"vpn_session_duration" => vpn_session_duration}},
        socket
      ) do
    configuration = Configurations.get_configuration!()

    case Configurations.update_configuration(configuration, %{
           vpn_session_duration: vpn_session_duration
         }) do
      {:ok, configuration} ->
        {:noreply,
         socket
         |> assign(:form_changed, false)
         |> assign(:configuration_changeset, Configurations.change_configuration(configuration))}

      {:error, configuration_changeset} ->
        {:noreply,
         socket
         |> assign(:configuration_changeset, configuration_changeset)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle", %{"config" => config} = params, socket) do
    toggle_value = !!params["value"]
    {:ok, _conf} = Configurations.update_configuration(%{config => toggle_value})
    {:noreply, socket}
  end

  @types %{"oidc" => :openid_connect_providers, "saml" => :saml_identity_providers}

  @impl Phoenix.LiveView
  def handle_event("delete", %{"type" => type, "key" => key}, socket) do
    field_key = Map.fetch!(@types, type)

    providers =
      socket.assigns.config_changeset.data
      |> Map.fetch!(field_key)
      |> Enum.reject(&(&1.id == key))
      |> Enum.map(&Map.from_struct/1)

    {:ok, configuration} = Configurations.update_configuration(%{field_key => providers})

    socket =
      socket
      |> assign(:config_changeset, Configurations.change_configuration(configuration))
      |> assign(:oidc_configs, map_providers(configuration.openid_connect_providers))
      |> assign(:saml_configs, map_providers(configuration.saml_identity_providers))

    {:noreply, socket}
  end

  @hour 3_600
  @day 24 * @hour

  def session_duration_options do
    [
      Never: 0,
      Once: FzHttp.Configurations.Configuration.Changeset.max_vpn_session_duration(),
      "Every Hour": @hour,
      "Every Day": @day,
      "Every Week": 7 * @day,
      "Every 30 Days": 30 * @day,
      "Every 90 Days": 90 * @day
    ]
  end

  defp configuration_changeset do
    Configurations.get_configuration!()
    |> Configurations.change_configuration()
  end

  @fields ~w(
    local_auth_enabled
    disable_vpn_on_oidc_error
    allow_unprivileged_device_management
    allow_unprivileged_device_configuration
    openid_connect_providers
  )a
  @override_title """
  This value is currently overriding the value set in your configuration file.
  """
  defp field_titles(changeset) do
    @fields
    |> Map.new(fn key ->
      if is_nil(get_field(changeset, key)) do
        {key, ""}
      else
        {key, @override_title}
      end
    end)
  end
end
