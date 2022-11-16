defmodule FzHttp.OIDC.StartProxy do
  @moduledoc """
  This proxy simply gets the relevant config at an appropriate timing
  (after `FzHttp.Configurations.Cache` has started) and pass to `OpenIDConnect.Worker`
  """

  alias FzHttp.Configurations, as: Conf

  require Logger

  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  end

  def start_link(:test) do
    auth_oidc_env = Conf.get!(:openid_connect_providers)
    Conf.Cache.put!(:parsed_openid_connect_providers, parse(auth_oidc_env))
    :ignore
  end

  def start_link(_) do
    auth_oidc_env = Conf.get!(:openid_connect_providers)

    if parsed = auth_oidc_env && parse(auth_oidc_env) do
      Conf.Cache.put!(:parsed_openid_connect_providers, parsed)
      OpenIDConnect.Worker.start_link(parsed)
    else
      :ignore
    end
  end

  defp parse(auth_oidc_env) when is_binary(auth_oidc_env) do
    auth_oidc_env |> Jason.decode!() |> parse()
  end

  defp parse(auth_oidc_config) when is_map(auth_oidc_config) do
    external_url = Application.fetch_env!(:fz_http, :external_url)

    # Convert Map to something openid_connect expects, atomic keyed configs
    # eg. [provider: [client_id: "CLIENT_ID" ...]]
    Enum.map(auth_oidc_config, fn {provider, settings} ->
      {
        String.to_atom(provider),
        [
          discovery_document_uri: settings["discovery_document_uri"],
          client_id: settings["client_id"],
          client_secret: settings["client_secret"],
          redirect_uri: settings["redirect_uri"] || "#{external_url}/auth/oidc/#{provider}/callback/",
          response_type: settings["response_type"],
          scope: settings["scope"],
          label: settings["label"]
        ]
      }
    end)
  end
end
