defmodule FzHttp.OIDC.StartProxy do
  @moduledoc """
  This proxy simply gets the relevant config at an appropriate timing
  """

  require Logger

  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  end

  def start_link(:test) do
    :ignore
  end

  def start_link(_) do
    FzHttp.Configurations.get!(:openid_connect_providers)
    |> parse()
    |> OpenIDConnect.Worker.start_link()
  end

  # XXX: Remove when configurations support test fixtures
  if Mix.env() == :test do
    def restart, do: :ignore
  else
    def restart do
      :ok = Supervisor.terminate_child(FzHttp.Supervisor, __MODULE__)
      Supervisor.restart_child(FzHttp.Supervisor, __MODULE__)
    end
  end

  # Convert the configuration record to something openid_connect expects,
  # atom-keyed configs eg. [provider: [client_id: "CLIENT_ID" ...]]
  defp parse(nil), do: []

  defp parse(auth_oidc_config) when is_list(auth_oidc_config) do
    external_url = FzHttp.Config.fetch_env!(:fz_http, :external_url)

    Enum.map(auth_oidc_config, fn provider ->
      {
        String.to_atom(provider.id),
        [
          discovery_document_uri: provider.discovery_document_uri,
          client_id: provider.client_id,
          client_secret: provider.client_secret,
          redirect_uri:
            provider.redirect_uri || "#{external_url}/auth/oidc/#{provider.id}/callback/",
          response_type: provider.response_type,
          scope: provider.scope,
          label: provider.label
        ]
      }
    end)
  end
end
