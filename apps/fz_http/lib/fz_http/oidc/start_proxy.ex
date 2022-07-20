defmodule FzHttp.OIDC.StartProxy do
  @moduledoc """
  This proxy simply gets the relevant config at an appropriate timing
  (after `FzHttp.Conf.Cache` has started) and pass to `OpenIDConnect.Worker`'s own child_spec/1
  """

  def child_spec(_) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  def start_link(_) do
    auth_oidc_env = FzHttp.Conf.get(:openid_connect_providers)

    openid_connect_providers =
      case auth_oidc_env do
        nil -> nil
        string when is_binary(string) -> parse_env(string)
        value when is_map(value) or is_list(value) -> value
      end

    if openid_connect_providers do
      OpenIDConnect.Worker.start_link(openid_connect_providers)
    else
      :ignore
    end
  end

  defp parse_env(auth_oidc_env) do
    external_url = Application.fetch_env!(:fz_http, :external_url)

    Jason.decode!(auth_oidc_env)
    # Convert Map to something openid_connect expects, atomic keyed configs
    # eg. [provider: [client_id: "CLIENT_ID" ...]]
    |> Enum.map(fn {provider, settings} ->
      {
        String.to_atom(provider),
        [
          discovery_document_uri: settings["discovery_document_uri"],
          client_id: settings["client_id"],
          client_secret: settings["client_secret"],
          redirect_uri: "#{external_url}/auth/oidc/#{provider}/callback/",
          response_type: settings["response_type"],
          scope: settings["scope"],
          label: settings["label"]
        ]
      }
    end)
  end
end
