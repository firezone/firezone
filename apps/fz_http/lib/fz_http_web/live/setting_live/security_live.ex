defmodule FzHttpWeb.SettingLive.Security do
  @moduledoc """
  Manages security LiveView
  """
  use FzHttpWeb, :live_view
  import FzCommon.FzCrypto, only: [rand_string: 1]
  alias FzHttp.Config

  @page_title "Security Settings"
  @page_subtitle "Configure security-related settings."

  @hour 3_600
  @day 24 * @hour

  @configs ~w[
    local_auth_enabled
    disable_vpn_on_oidc_error
    allow_unprivileged_device_management
    allow_unprivileged_device_configuration
    vpn_session_duration
    openid_connect_providers
    saml_identity_providers
  ]a

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, @page_title)
      |> assign(:page_subtitle, @page_subtitle)
      # TODO: just use changeset.changes == %{}
      |> assign(:form_changed, false)
      |> assign(:configuration_changeset, configuration_changeset())
      |> assign(:configs, FzHttp.Config.fetch_source_and_configs!(@configs))

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :id, params["id"])}
  end

  @impl Phoenix.LiveView
  def handle_event("change", _params, socket) do
    {:noreply, assign(socket, :form_changed, true)}
  end

  @impl Phoenix.LiveView
  def handle_event(
        "save_configuration",
        %{"configuration" => %{"vpn_session_duration" => vpn_session_duration}},
        socket
      ) do
    configuration = Config.fetch_db_config!()

    attrs = %{
      vpn_session_duration: vpn_session_duration
    }

    socket =
      case Config.update_config(configuration, attrs) do
        {:ok, configuration} ->
          socket
          |> assign(:form_changed, false)
          |> assign(:configuration_changeset, Config.change_config(configuration))

        {:error, configuration_changeset} ->
          socket
          |> assign(:configuration_changeset, configuration_changeset)
      end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle", %{"config" => key} = params, socket) do
    Config.put_config!(key, !!params["value"])
    configs = FzHttp.Config.fetch_source_and_configs!(@configs)
    {:noreply, assign(socket, :configs, configs)}
  end

  @impl Phoenix.LiveView
  def handle_event("delete", %{"type" => type, "key" => key}, socket) do
    field_key = String.to_existing_atom(type)

    providers =
      Config.fetch_db_config!()
      |> Map.fetch!(field_key)
      |> Enum.reject(&(&1.id == key))
      |> Enum.map(&Map.from_struct/1)

    Config.put_config!(field_key, providers)
    configs = FzHttp.Config.fetch_source_and_configs!(@configs)

    {:noreply, assign(socket, :configs, configs)}
  end

  def config_has_override?({{source, _source_key}, _key}), do: source not in [:db]
  def config_has_override?({_source, _key}), do: false

  def config_value({_source, value}) do
    value
  end

  def get_provider(providers, id) do
    Enum.find(providers, &(&1.id == id))
  end

  def config_toggle_status({_source, value}) do
    if(!value, do: "on")
  end

  def config_override_source({{:env, source_key}, _value}) do
    "environment variable #{source_key}"
  end

  def session_duration_options(vpn_session_duration) do
    options = [
      {"Never", 0},
      {"Once", FzHttp.Config.Configuration.Changeset.max_vpn_session_duration()},
      {"Every Hour", @hour},
      {"Every Day", @day},
      {"Every Week", 7 * @day},
      {"Every 30 Days", 30 * @day},
      {"Every 90 Days", 90 * @day}
    ]

    values = Enum.map(options, fn {_, value} -> value end)

    if config_value(vpn_session_duration) in values do
      options
    else
      options ++
        [
          {"Every #{config_value(vpn_session_duration)} seconds",
           config_value(vpn_session_duration)}
        ]
    end
  end

  defp configuration_changeset do
    Config.fetch_db_config!()
    |> Config.change_config()
  end
end
