defmodule FzHttpWeb.SettingLive.Security do
  @moduledoc """
  Manages security LiveView
  """
  use FzHttpWeb, :live_view

  import Ecto.Changeset
  import FzCommon.FzCrypto, only: [rand_string: 1]

  alias FzHttp.Configurations, as: Conf
  alias FzHttp.{Sites, Sites.Site}

  @page_title "Security Settings"
  @page_subtitle "Configure security-related settings."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    config_changeset = Conf.change_configuration()

    {:ok,
     socket
     |> assign(:form_changed, false)
     |> assign(:session_duration_options, session_duration_options())
     |> assign(:site_changeset, site_changeset())
     |> assign(:config_changeset, config_changeset)
     |> assign(:oidc_configs, config_changeset.data.openid_connect_providers || %{})
     |> assign(:saml_configs, config_changeset.data.saml_identity_providers || %{})
     |> assign(:field_titles, field_titles(config_changeset))
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
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
        "save_site",
        %{"site" => %{"vpn_session_duration" => vpn_session_duration}},
        socket
      ) do
    site = Sites.get_site!()

    case Sites.update_site(site, %{vpn_session_duration: vpn_session_duration}) do
      {:ok, site} ->
        {:noreply,
         socket
         |> assign(:form_changed, false)
         |> assign(:site_changeset, Sites.change_site(site))}

      {:error, site_changeset} ->
        {:noreply,
         socket
         |> assign(:site_changeset, site_changeset)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle", %{"config" => config} = params, socket) do
    toggle_value = !!params["value"]
    {:ok, _conf} = Conf.update_configuration(%{config => toggle_value})
    {:noreply, socket}
  end

  @types %{"oidc" => :openid_connect_providers, "saml" => :saml_identity_providers}

  @impl Phoenix.LiveView
  def handle_event("delete", %{"type" => type, "key" => key}, socket) do
    field_key = Map.fetch!(@types, type)

    providers =
      get_in(socket.assigns.config_changeset, [Access.key!(:data), Access.key!(field_key)])

    {:ok, conf} = Conf.update_configuration(%{field_key => Map.delete(providers, key)})

    {:noreply,
     socket
     |> assign(String.to_existing_atom("#{type}_configs"), get_in(conf, [Access.key!(field_key)]))
     |> assign(:config_changeset, change(conf))}
  end

  @hour 3_600
  @day 24 * @hour

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

  defp site_changeset do
    Sites.get_site!()
    |> Sites.change_site()
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
