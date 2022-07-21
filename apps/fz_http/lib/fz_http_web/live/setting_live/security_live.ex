defmodule FzHttpWeb.SettingLive.Security do
  @moduledoc """
  Manages security LiveView
  """
  use FzHttpWeb, :live_view

  import Ecto.Changeset

  alias FzHttp.{Conf, Sites, Sites.Site}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    config_changeset = Conf.change_configuration()

    {:ok,
     socket
     |> assign(:form_changed, false)
     |> assign(:session_duration_options, session_duration_options())
     |> assign(:site_changeset, site_changeset())
     |> assign(:config_changeset, config_changeset)
     |> assign(:configs, config_changeset.data)
     |> assign(:page_title, "Security Settings")}
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
    toggle_value = !params["value"]
    {:ok, conf} = Conf.update_configuration(%{config => toggle_value})
    {:noreply, assign(socket, :configs, conf)}
  end

  @impl Phoenix.LiveView
  def handle_event(
        "save_oidc_config",
        %{"configuration" => %{"openid_connect_providers" => config}},
        socket
      ) do
    with {:ok, json} <- Jason.decode(config),
         {:ok, conf} <- Conf.update_configuration(%{openid_connect_providers: json}) do
      :ok = Supervisor.terminate_child(FzHttp.Supervisor, FzHttp.OIDC.StartProxy)
      {:ok, _pid} = Supervisor.restart_child(FzHttp.Supervisor, FzHttp.OIDC.StartProxy)
      {:noreply, assign(socket, :config_changeset, Conf.change_configuration(conf))}
    else
      {:error, %Jason.DecodeError{}} ->
        {:noreply,
         assign(
           socket,
           :config_changeset,
           Conf.change_configuration()
           |> put_change(:openid_connect_providers, config)
           |> add_error(:openid_connect_providers, "Invalid JSON configuration")
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :config_changeset, changeset)}
    end
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
end
