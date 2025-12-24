defmodule Portal.ComponentVersions do
  alias Portal.{Client, ComponentVersions}
  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl true
  def init(_opts) do
    fetch_from_url? =
      Portal.Config.fetch_env!(:domain, ComponentVersions)
      |> Keyword.get(:fetch_from_url)

    children =
      if fetch_from_url? do
        [ComponentVersions.Refresher]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  def gateway_version do
    ComponentVersions.component_version(:gateway)
  end

  def client_version(%Client{} = client) do
    client
    |> get_component_type()
    |> component_version()
  end

  def component_version(component) do
    Portal.Config.get_env(:domain, ComponentVersions, [])
    |> Keyword.get(:versions, [])
    |> Keyword.get(component, "0.0.0")
  end

  def fetch_versions do
    config = fetch_config!()
    releases_url = Keyword.fetch!(config, :firezone_releases_url)
    fetch_from_url? = Keyword.fetch!(config, :fetch_from_url)

    if fetch_from_url? do
      fetch_versions_from_url(releases_url)
    else
      {:ok, Keyword.fetch!(config, :versions)}
    end
  end

  def get_component_type(%Client{last_seen_user_agent: "Mac OS" <> _rest}), do: :apple
  def get_component_type(%Client{last_seen_user_agent: "iOS" <> _rest}), do: :apple

  def get_component_type(%Client{last_seen_user_agent: "Android" <> _rest}),
    do: :android

  def get_component_type(%Client{actor: %Portal.Actor{type: :service_account}}), do: :headless

  def get_component_type(_), do: :gui

  defp fetch_config! do
    Portal.Config.fetch_env!(:domain, __MODULE__)
  end

  defp fetch_versions_from_url(releases_url) do
    case Req.get(releases_url) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        versions = decode_versions_response(body)
        {:ok, Enum.into(versions, [])}

      {:ok, response} ->
        Logger.warning("Can't fetch Firezone versions", reason: inspect(response))
        {:error, {response.status, response.body}}

      {:error, reason} ->
        Logger.warning("Can't fetch Firezone versions", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp decode_versions_response(%{
         "apple" => apple,
         "android" => android,
         "gateway" => gateway,
         "gui" => gui,
         "headless" => headless
       }) do
    %{apple: apple, android: android, gateway: gateway, gui: gui, headless: headless}
  end

  defp decode_versions_response(_response) do
    fetch_config!()
    |> Keyword.fetch!(:versions)
  end
end
